#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Separates production lines from a file's trailing #[cfg(test)] module for the src/ text scans
# ABOUTME: Filter mode drops `path:line:` matches inside the test module; --check enforces the layout the filter assumes
#
# Rust unit tests live in `#[cfg(test)] mod tests { ... }` inside the module
# they test, where `unwrap`/`expect`/`panic!` are as legitimate as they are in
# `tests/`. validate.sh's text scans over `src/` count those calls, so they
# pipe their matches through this filter to count production code only; a
# repo's own scans can do the same.
#
# The assumption, which is the Rust convention and which `--check` enforces:
# a file's test module is an INLINE module, attached to a column-0
# `#[cfg(test)]`, and it is the LAST item in the file. Everything from that
# attribute to end-of-file is test code; everything before it is production.
# rustfmt indents every item inside the module, so a column-0 line after the
# module's opening brace (other than its closing `}`) is an item that follows
# the test module, and the filter would wrongly hide it. `--check` fails on
# exactly that, on a `#[cfg(test)]` that does not open an inline module (a
# test-only `fn`/`use` at top level, or `mod tests;` in another file), and on
# a second test module.
#
# `--check` reads layout, not Rust. Inside and after the test module it flags
# only column-0 lines that open an item (`fn`, `pub`, `impl`, `use`, an
# attribute, ...), so a raw string whose lines start at column 0 passes unless
# a line of it looks like one. Several trailing test modules in a row are
# accepted: the filter strips from the first to end-of-file.
#
# An indented `#[cfg(test)]` (inside an `impl` or a nested module) is not
# stripped: its body is scanned as production code, so the scan fails loud
# rather than passing silently.
#
# Usage:
#   rg -n --with-filename PATTERN crates/x/src | test-module-lines.sh   # filter
#   test-module-lines.sh --check PATH...                                # layout gate
#
# Filter input is ripgrep's `path:line:content` shape; paths are opened as
# given, so run it from the directory ripgrep ran in. A line whose path
# cannot be read is kept, never dropped.

set -euo pipefail

# The awk below is POSIX (the CI runners' awk is mawk): no gawk extensions.
# shellcheck disable=SC2016
CUTOFF_AWK='
function cutoff(path,    text, n, pending) {
    n = 0; pending = 0
    while ((getline text < path) > 0) {
        n++
        if (pending) {
            # Further attributes, including a multi-line #[allow(...)] whose
            # continuation lines are indented or close with `)]`.
            if (text ~ /^#\[/ || text ~ /^[ \t]/ || text ~ /^\)?\]/) continue
            if (text ~ /^(pub(\([a-z]+\))? )?mod [A-Za-z_][A-Za-z0-9_]* \{[ \t]*$/) {
                close(path); return pending
            }
            pending = 0
        }
        if (text ~ /^#\[cfg\(test\)\][ \t]*$/) pending = n
    }
    close(path)
    return 0
}
'

if [[ "${1:-}" == "--check" ]]; then
    shift
    if [[ $# -eq 0 ]]; then
        echo "test-module-lines.sh --check: no paths given" >&2
        exit 2
    fi
    # rg exits 1 for "no file has a test module", which is a clean result;
    # anything else (a missing path, rg absent) must fail, not read as clean.
    rc=0
    files=$(rg -l --glob '*.rs' '^#\[cfg\(test\)\]' "$@") || rc=$?
    if [[ $rc -gt 1 ]]; then
        echo "test-module-lines.sh --check: rg failed (exit $rc)" >&2
        exit 2
    fi
    violations=$(printf '%s\n' "$files" | sed '/^$/d' | sort | while IFS= read -r file; do
        awk -v ITEM='^(pub[ (]|fn |impl[ <]|struct |enum |union |mod |use |const |static |trait |type [A-Za-z_]|macro_rules!|async |unsafe |extern |#!?\\[)' '
            BEGIN { state = "prod" }
            {
                if (state == "prod") {
                    if ($0 ~ /^#\[cfg\(test\)\][ \t]*$/) { state = "attr"; attr = NR }
                    next
                }
                if (state == "attr") {
                    if ($0 ~ /^#\[/ || $0 ~ /^[ \t]/ || $0 ~ /^\)?\]/) next
                    if ($0 ~ /^(pub(\([a-z]+\))? )?mod [A-Za-z_][A-Za-z0-9_]* \{[ \t]*$/) { state = "module"; next }
                    printf "%s:%d: #[cfg(test)] must open an inline `mod tests { ... }`\n", FILENAME, attr
                    state = "prod"; next
                }
                if (state == "module") {
                    if ($0 ~ /^}[ \t]*$/) { state = "closed"; next }
                    if ($0 ~ ITEM) {
                        printf "%s:%d: item at column 0 inside or after the test module; the test module must be the last item\n", FILENAME, NR
                        state = "done"
                    }
                    next
                }
                if (state == "closed") {
                    # Another trailing test module is fine: the filter strips
                    # from the first one to end-of-file.
                    if ($0 ~ /^#\[cfg\(test\)\][ \t]*$/) { state = "attr"; attr = NR; next }
                    if ($0 ~ ITEM) {
                        printf "%s:%d: item after the test module; the test module must be the last item\n", FILENAME, NR
                        state = "done"
                    }
                }
            }
            END {
                if (state == "attr") printf "%s:%d: #[cfg(test)] must open an inline `mod tests { ... }`\n", FILENAME, attr
                if (state == "module") printf "%s:%d: test module is not closed at column 0\n", FILENAME, attr
            }
        ' "$file"
    done)
    if [[ -n "$violations" ]]; then
        echo "$violations"
        exit 1
    fi
    exit 0
fi

awk -F: "$CUTOFF_AWK"'
{
    path = $1
    if (!(path in cut)) cut[path] = cutoff(path)
    if (cut[path] == 0 || $2 + 0 < cut[path]) print
}
'
