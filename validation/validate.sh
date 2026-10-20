#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Universal architectural validation for all dravr-* Rust projects
# ABOUTME: The dravr-wide rules are written here; validation-patterns.local.toml holds a repo's own switches

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOCAL_PATTERNS_FILE="$PROJECT_ROOT/validation-patterns.local.toml"

VALIDATION_FAILED=false

# Every scan below is ripgrep-based, and each one redirects rg's own errors to
# /dev/null so a missing binary reads as "no matches" — i.e. as a clean repo.
# Verified: with rg off PATH this script reports "No continue-on-error in CI"
# on a repo that has one. A validator that passes when it cannot run is worse
# than no validator, and this one now gates every push.
if ! command -v rg > /dev/null 2>&1; then
    echo -e "${RED}❌ ripgrep (rg) not found — every check here depends on it${NC}"
    echo "   Install it (brew install ripgrep / apt-get install -y ripgrep) and re-run."
    echo "   Refusing to report success from checks that cannot run."
    exit 1
fi

fail_validation() {
    echo -e "${RED}❌ $1${NC}"
    VALIDATION_FAILED=true
}

pass_validation() {
    echo -e "${GREEN}✅ $1${NC}"
}

warn_validation() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# prod_src_matches <out-file> <pattern> <rg paths and flags…>
# Writes to <out-file> the matches in production code only: `path:line:content` for
# every match, minus the lines inside a file's trailing `#[cfg(test)] mod tests { ... }`.
# A unit test's unwrap, expect, panic!, mock or `let _x` is test code, exactly as it is
# under tests/. test-module-lines.sh documents the layout it assumes; a file whose
# layout --check flags (MISREAD_FILES, below) is kept whole, unfiltered, so a layout the
# filter would misread can only add matches, never hide production code.
#
# Each step's exit status is checked on its own (carnet#941): a scan that pipes rg into
# the filter and counts lines reads a crashed filter as a clean tree. An rg that could
# not search, or a filter that could not run, fails the validation and returns 1, and
# the caller then reports no verdict for that scan. So does a split by layout that
# could not run (carnet#927): an awk that died there left the filter nothing to read,
# and the scan counted zero.
TEST_MODULE_LINES="$SCRIPT_DIR/test-module-lines.sh"
prod_src_matches() {
    local out="$1" pattern="$2" rc=0
    shift 2
    rg -n --with-filename "$pattern" "$@" >"$out.raw" 2>"$out.err" < /dev/null || rc=$?
    if [ "$rc" -gt 1 ]; then
        fail_validation "rg could not scan for '$pattern' (exit $rc) — nothing was checked"
        sed 's/^/   /' "$out.err" | head -5
        return 1
    fi
    # shellcheck disable=SC2016
    local split='BEGIN { while ((getline f < MISREAD) > 0) misread[f] = 1; close(MISREAD) }'
    if ! awk -F: -v MISREAD="$MISREAD_FILES" "$split"' ($1 in misread)' "$out.raw" >"$out.whole" 2>"$out.err" ||
       ! awk -F: -v MISREAD="$MISREAD_FILES" "$split"' !($1 in misread)' "$out.raw" >"$out.unfiltered" 2>"$out.err"; then
        fail_validation "could not split the '$pattern' matches by test-module layout — the scan was not checked"
        sed 's/^/   /' "$out.err" | head -5
        return 1
    fi
    if ! "$TEST_MODULE_LINES" <"$out.unfiltered" >"$out.filtered" 2>"$out.err"; then
        fail_validation "test-module filter failed ($TEST_MODULE_LINES) — the '$pattern' scan was not checked"
        sed 's/^/   /' "$out.err" | head -5
        return 1
    fi
    cat "$out.filtered" "$out.whole" >"$out"
}

# drop_lines <file> <pattern>: removes, in place, every line of <file> matching <pattern>.
# It is how a scan exempts a line, and it returns 1 when rg could not run: rg -v exits 1
# when it drops every line, which is a clean result, and above 1 when it searched nothing.
# A `{ rg -v … || true; }` read that crash as "every line exempted" (carnet#927).
drop_lines() {
    local rc=0
    rg -v "$2" "$1" >"$1.kept" 2>"$1.err" < /dev/null || rc=$?
    if [ "$rc" -gt 1 ]; then
        sed 's/^/   /' "$1.err" | head -5
        return 1
    fi
    mv "$1.kept" "$1"
}

# count_lines <file>: how many non-empty lines <file> holds. Under set -e an awk that
# cannot read the file stops the script, where `grep -c . || true` printed nothing and
# the caller's ${n:-0} read it as zero findings.
count_lines() {
    awk 'NF { n++ } END { print n + 0 }' "$1"
}

# rg_capture <scan> <out-file> <rg args…>: writes rg's output to <out-file>. rg exits 1
# when nothing matches, which is a clean result, and above 1 when it could not search:
# that fails the validation, prints rg's error and returns 1, and the caller then reports
# no verdict for <scan>. A `rg … 2>/dev/null | awk` read that crash as zero findings, and
# the scan printed a pass (carnet#1093).
rg_capture() {
    local scan="$1" out="$2" rc=0
    shift 2
    rg "$@" >"$out" 2>"$out.err" < /dev/null || rc=$?
    if [ "$rc" -gt 1 ]; then
        fail_validation "rg could not run the $scan scan (exit $rc) — it was not checked"
        sed 's/^/   /' "$out.err" | head -5
        return 1
    fi
}

# sum_counts <file>: the total of an rg --count or --count-matches output, one `path:n`
# line per file, or a bare `n` when rg searched a single file.
sum_counts() {
    awk -F: '{ sum += $NF } END { print sum + 0 }' "$1"
}

# Determine scan paths
SRC_PATHS=""
TEST_PATHS=""
if [ -d "$PROJECT_ROOT/crates" ]; then
    SRC_PATHS="$PROJECT_ROOT/crates/*/src/"
    # Only when some crate has one: an unmatched glob reaches rg as a literal path, and
    # rg then exits 2, which the test scans below now read as a search that failed.
    if compgen -G "$PROJECT_ROOT/crates/*/tests/" > /dev/null; then
        TEST_PATHS="$PROJECT_ROOT/crates/*/tests/"
    fi
fi
if [ -d "$PROJECT_ROOT/src" ]; then
    SRC_PATHS="$SRC_PATHS $PROJECT_ROOT/src/"
fi
if [ -d "$PROJECT_ROOT/tests" ]; then
    TEST_PATHS="$TEST_PATHS $PROJECT_ROOT/tests/"
fi

# Verify we have something to scan
if [ -z "$SRC_PATHS" ]; then
    echo -e "${YELLOW}No Rust source directories found, skipping${NC}"
    exit 0
fi

echo -e "${BLUE}==== Dravr Architectural Validation ====${NC}"
echo "Project: $PROJECT_ROOT"
echo "Sources: $SRC_PATHS"

cd "$PROJECT_ROOT"

SCAN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/validate.XXXXXX") || { echo -e "${RED}❌ mktemp failed — nothing was checked${NC}"; exit 1; }
trap 'rm -rf "$SCAN_TMP"' EXIT

# The test-module layout, read before the src/ scans because they depend on it: every
# file --check flags is scanned whole (see prod_src_matches). Its verdict is reported
# in the "Test module layout" section below; a check that could not run at all is a
# failure there, since no file's layout is then known.
MISREAD_FILES="$SCAN_TMP/misread-files"
LAYOUT_RC=0
# shellcheck disable=SC2086
LAYOUT_ERRORS=$("$TEST_MODULE_LINES" --check $SRC_PATHS 2>"$SCAN_TMP/layout.err" < /dev/null) || LAYOUT_RC=$?
# Each step is judged on its own: a sed or sort that died here would leave a misread file
# out of the list, and the filter would then hide the production code after its tests.
if ! printf '%s\n' "$LAYOUT_ERRORS" | sed -n 's/^\(.*\):[0-9][0-9]*: .*/\1/p' >"$MISREAD_FILES.unsorted" ||
   ! sort -u "$MISREAD_FILES.unsorted" >"$MISREAD_FILES"; then
    echo -e "${RED}❌ could not list the files whose test-module layout the filter would misread — nothing was checked${NC}"
    exit 1
fi

# ============================================================================
# FAST-FAIL: Backup files
# ============================================================================
echo ""
echo -e "${BLUE}Checking for backup files...${NC}"
BACKUP_FILES=$(find $SRC_PATHS -name "*.backup" -o -name "*.bak" -o -name "*~" 2>/dev/null | head -5)
if [ -n "$BACKUP_FILES" ]; then
    fail_validation "Backup files found — remove before committing"
    echo "$BACKUP_FILES"
else
    pass_validation "No backup files"
fi

# ============================================================================
# Placeholder detection
# ============================================================================
echo -e "${BLUE}Checking for placeholder implementations...${NC}"
# Every rule lives in this file (carnet#942): a separate patterns file that nothing read
# had drifted from these lists. The phrases are matched case-insensitively, except the
# two sentence openings that ordinary prose writes in lower case ("a second
# implementation would mean…", "callers should implement the trait"). A bare
# PLACEHOLDER is not a rule: it is how prompt templates name their {{PLACEHOLDER}} tokens.
PLACEHOLDER_PATTERNS="stub implementation|stub for now|stub endpoint|mock implementation|placeholder implementation|placeholder structure|simplified placeholder|this is a placeholder|is a placeholder that|dummy implementation|will be implemented|to be implemented|not yet implemented|In future versions|Implement the code|return mock data|TODO: Implementation|available for real implementation|Would implement|Will implement|(?-i:Implementation would)|(?-i:Should implement)"
# Exclude comments (/// and //) to avoid matching documentation that describes placeholders
# shellcheck disable=SC2086
if rg_capture "placeholder" "$SCAN_TMP/placeholders" -i -n "$PLACEHOLDER_PATTERNS" $SRC_PATHS; then
    if ! drop_lines "$SCAN_TMP/placeholders" "^\s*///|^\s*//"; then
        fail_validation "the placeholder comment filter could not run — the placeholder scan was not checked"
    else
        PLACEHOLDERS=$(count_lines "$SCAN_TMP/placeholders")
        if [ "$PLACEHOLDERS" -gt 0 ]; then
            fail_validation "Found $PLACEHOLDERS placeholder implementations"
            head -5 "$SCAN_TMP/placeholders"
        else
            pass_validation "No placeholder implementations"
        fi
    fi
fi

# ============================================================================
# Error handling: anyhow forbidden
# ============================================================================
echo -e "${BLUE}Checking for forbidden anyhow usage...${NC}"
# A fully qualified `-> anyhow::Result<()>` needs no `use` line, so it is counted on its own.
# shellcheck disable=SC2086
if rg_capture "anyhow macro" "$SCAN_TMP/anyhow-macro" "\\banyhow!\\(|anyhow::anyhow!\\(" $SRC_PATHS --count &&
   rg_capture "anyhow import" "$SCAN_TMP/anyhow-imports" "use anyhow::" $SRC_PATHS --count &&
   rg_capture "anyhow type" "$SCAN_TMP/anyhow-types" "anyhow::(Result|Error)\\b" $SRC_PATHS --count; then
    ANYHOW_MACRO=$(sum_counts "$SCAN_TMP/anyhow-macro")
    ANYHOW_IMPORTS=$(sum_counts "$SCAN_TMP/anyhow-imports")
    ANYHOW_TYPES=$(sum_counts "$SCAN_TMP/anyhow-types")
    ANYHOW_TOTAL=$((ANYHOW_MACRO + ANYHOW_IMPORTS + ANYHOW_TYPES))
    if [ "$ANYHOW_TOTAL" -gt 0 ]; then
        fail_validation "Found $ANYHOW_TOTAL anyhow usages (use structured error types)"
        rg "\\banyhow!\\(|use anyhow::|anyhow::(Result|Error)\\b" $SRC_PATHS -n 2>/dev/null | head -5
    else
        pass_validation "No anyhow usage"
    fi
fi

# ============================================================================
# Problematic unwraps/expects/panics
# ============================================================================
echo -e "${BLUE}Checking for problematic error handling...${NC}"
# --no-filename so the comment filter sees the source line itself: a `///` doc
# comment explaining that `Row::get` is `try_get().unwrap()` is prose, not a call.
# The filenames are cut back off after the test-module filter so the comment
# filter sees the source line itself, as it did with --no-filename.
# shellcheck disable=SC2086
if prod_src_matches "$SCAN_TMP/unwraps" "\.unwrap\(\)" $SRC_PATHS &&
   prod_src_matches "$SCAN_TMP/expects" "\.expect\(" $SRC_PATHS &&
   prod_src_matches "$SCAN_TMP/panics" "panic!\(" $SRC_PATHS; then
    cut -d: -f3- "$SCAN_TMP/unwraps" >"$SCAN_TMP/unwraps.code"
    cut -d: -f3- "$SCAN_TMP/expects" >"$SCAN_TMP/expects.code"
    if ! drop_lines "$SCAN_TMP/unwraps.code" "^\s*//" ||
       ! drop_lines "$SCAN_TMP/unwraps.code" "// Safe|hardcoded.*valid|static.*data" ||
       ! drop_lines "$SCAN_TMP/expects.code" "^\s*//" ||
       ! drop_lines "$SCAN_TMP/expects.code" "// Safe"; then
        fail_validation "the unwrap/expect exemption filter could not run — the error handling scan was not checked"
    else
        UNWRAPS=$(count_lines "$SCAN_TMP/unwraps.code")
        EXPECTS=$(count_lines "$SCAN_TMP/expects.code")
        PANICS=$(count_lines "$SCAN_TMP/panics")
        if [ "${UNWRAPS:-0}" -gt 0 ]; then
            fail_validation "Found $UNWRAPS problematic .unwrap() calls"
        fi
        if [ "${EXPECTS:-0}" -gt 0 ]; then
            fail_validation "Found $EXPECTS problematic .expect() calls"
        fi
        if [ "${PANICS:-0}" -gt 0 ]; then
            fail_validation "Found $PANICS panic!() calls in production code"
        fi
        if [ "${UNWRAPS:-0}" -eq 0 ] && [ "${EXPECTS:-0}" -eq 0 ] && [ "${PANICS:-0}" -eq 0 ]; then
            pass_validation "No problematic error handling"
        fi
    fi
fi

# ============================================================================
# TODOs/FIXMEs
# ============================================================================
echo -e "${BLUE}Checking for incomplete code markers...${NC}"
# rg_capture's `< /dev/null` is load-bearing: with an empty path variable rg falls back
# to reading stdin and blocks forever. A repo with no tests/ directory hung this
# script indefinitely (CI only survived it because its stdin is already closed).
TODO_SCANNED=true
# shellcheck disable=SC2086
rg_capture "TODO marker" "$SCAN_TMP/todos" "\\b(TODO|FIXME|XXX)\\b" $SRC_PATHS -g "!*.json" -g "!*.md" --count || TODO_SCANNED=false
: >"$SCAN_TMP/todos-tests"
if [ -n "$TEST_PATHS" ]; then
    # shellcheck disable=SC2086
    rg_capture "TODO marker (tests)" "$SCAN_TMP/todos-tests" "\\b(TODO|FIXME|XXX)\\b" $TEST_PATHS -g "!*.json" -g "!*.md" --count || TODO_SCANNED=false
fi
if [ "$TODO_SCANNED" = true ]; then
    TODOS=$(sum_counts "$SCAN_TMP/todos")
    TODOS_TESTS=$(sum_counts "$SCAN_TMP/todos-tests")
    TODOS_TOTAL=$((TODOS + TODOS_TESTS))
    if [ "$TODOS_TOTAL" -gt 0 ]; then
        fail_validation "Found $TODOS_TOTAL TODO/FIXME/XXX markers (src:$TODOS tests:$TODOS_TESTS)"
    else
        pass_validation "No incomplete code markers"
    fi
fi

# ============================================================================
# Production mocks
# ============================================================================
echo -e "${BLUE}Checking for production mock code...${NC}"
# shellcheck disable=SC2086
if prod_src_matches "$SCAN_TMP/mocks" "mock_|get_mock|return.*mock|demo purposes|for demo|stub implementation|mock implementation" $SRC_PATHS -g "!*/bin/*" -g "!*/tests/*"; then
    if ! drop_lines "$SCAN_TMP/mocks" "// |/// |//!"; then
        fail_validation "the mock comment filter could not run — the production mock scan was not checked"
    else
        MOCKS=$(count_lines "$SCAN_TMP/mocks")
        if [ "$MOCKS" -gt 0 ]; then
            fail_validation "Found $MOCKS mock/stub patterns in production code"
            head -5 "$SCAN_TMP/mocks"
        else
            pass_validation "No production mocks"
        fi
    fi
fi

# ============================================================================
# Underscore-prefixed names
# ============================================================================
echo -e "${BLUE}Checking for underscore-prefixed names...${NC}"
# A `let _guard = lock.lock().await;` binding is the one underscore name that must
# stay: it holds an RAII guard to the end of scope, and "removing the variable"
# as `let _ = ...` drops the guard, and releases the lock, on the same line.
# shellcheck disable=SC2086
if prod_src_matches "$SCAN_TMP/underscores" "fn _[a-zA-Z]|let _[a-zA-Z]|struct _[a-zA-Z]|enum _[a-zA-Z]" $SRC_PATHS -g "!*/bin/*"; then
    if ! drop_lines "$SCAN_TMP/underscores" "let (mut )?_[a-z_]*guard\\b"; then
        fail_validation "the guard-binding filter could not run — the underscore-name scan was not checked"
    else
        UNDERSCORES=$(count_lines "$SCAN_TMP/underscores")
        if [ "$UNDERSCORES" -gt 0 ]; then
            fail_validation "Found $UNDERSCORES underscore-prefixed names (remove variable, don't hide it)"
            head -5 "$SCAN_TMP/underscores"
        else
            pass_validation "No underscore-prefixed names"
        fi
    fi
fi

# ============================================================================
# Forbidden clippy allows
# Catches both standalone `#[allow(clippy::xxx)]` and combined-form
# `#[allow(dead_code, clippy::xxx, clippy::yyy)]` by tokenizing each allow body
# on commas and checking each `clippy::*` token against the allowlist.
# ============================================================================
echo -e "${BLUE}Checking for unauthorized #[allow(clippy::...)]...${NC}"
ALLOWED_CLIPPY="cast_possible_truncation|cast_sign_loss|cast_precision_loss|cast_possible_wrap|struct_excessive_bools|too_many_lines|let_unit_value|option_if_let_else|cognitive_complexity|bool_to_int_with_if|type_complexity|too_many_arguments|use_self|trivially_copy_pass_by_ref|missing_const_for_fn"

# Load local extensions if present
if [ -f "$LOCAL_PATTERNS_FILE" ]; then
    LOCAL_ALLOWED=$(grep "^allowed_extra" "$LOCAL_PATTERNS_FILE" 2>/dev/null | sed 's/.*= "//' | sed 's/"$//' || echo "")
    if [ -n "$LOCAL_ALLOWED" ]; then
        ALLOWED_CLIPPY="$ALLOWED_CLIPPY|$LOCAL_ALLOWED"
    fi
fi

# -o prints each whole attribute, after its path and line: matching only `#[allow(`
# printed that prefix alone, so no lint name ever reached the allowlist and the scan
# could not fail (carnet#1093). -U lets one match span the lines of an attribute that
# rustfmt wrapped, which rg prints one prefixed line each; they are joined back into one
# line per attribute, or a wrapped allow read as no allow at all (carnet#1094).
# shellcheck disable=SC2086
if rg_capture "clippy allow" "$SCAN_TMP/clippy-allows.raw" "#\[allow\([^)]*\)\]" $SRC_PATHS -g "!*/bin/*" -U -o -n --with-filename; then
    awk '{
        line = $0; text = line; sub(/^[^:]*:[0-9]+:/, "", text)
        if (text ~ /^#\[allow\(/) { if (rec != "") print rec; rec = line }
        else { gsub(/^[[:space:]]+/, " ", text); rec = rec text }
    } END { if (rec != "") print rec }' "$SCAN_TMP/clippy-allows.raw" >"$SCAN_TMP/clippy-allows"
    CLIPPY_ALLOWS=$(sed -E 's/^.*#\[allow\(//; s/\)\].*$//' "$SCAN_TMP/clippy-allows" \
        | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep '^clippy::' \
        | grep -v -E "^clippy::($ALLOWED_CLIPPY)$" \
        | wc -l | tr -d ' ')
    if [ "${CLIPPY_ALLOWS:-0}" -gt 0 ]; then
        fail_validation "Found $CLIPPY_ALLOWS unauthorized #[allow(clippy::)] attributes"
        # Each attribute that holds a forbidden lint, even beside an allowed one.
        awk -v allowed="^clippy::($ALLOWED_CLIPPY)$" '{
            body = $0; sub(/^.*#\[allow\(/, "", body); sub(/\)\].*$/, "", body)
            n = split(body, lint, ",")
            for (i = 1; i <= n; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", lint[i])
                if (lint[i] ~ /^clippy::/ && lint[i] !~ allowed) { print; break }
            }
        }' "$SCAN_TMP/clippy-allows" | head -5
    else
        pass_validation "No unauthorized clippy allows"
    fi
fi

# ============================================================================
# Dead code annotations
# Catches combined-form `#[allow(dead_code, clippy::xxx)]` as well as the bare form, on
# one line or wrapped over several (-U).
# ============================================================================
echo -e "${BLUE}Checking for dead code hiding...${NC}"
# shellcheck disable=SC2086
if rg_capture "dead code" "$SCAN_TMP/dead-code" "#\[allow\([^)]*\bdead_code\b" $SRC_PATHS -U --count-matches; then
    DEAD_CODE=$(sum_counts "$SCAN_TMP/dead-code")
    if [ "$DEAD_CODE" -gt 0 ]; then
        fail_validation "Found $DEAD_CODE #[allow(dead_code)] — remove the dead code instead"
        rg -U "#\[allow\([^)]*\bdead_code\b" $SRC_PATHS -n 2>/dev/null | head -5
    else
        pass_validation "No dead code annotations"
    fi
fi

# ============================================================================
# Stub-function signature
# A function carrying both `clippy::unused_self` and `clippy::unnecessary_wraps`
# is the textbook stub: a method that doesn't use self AND a Result-returning
# function that never fails. Claude Code tends to leave these behind when it
# wires up types but skips the implementation. No legitimate function needs
# both lints suppressed simultaneously — implement it or delete it.
# ============================================================================
echo -e "${BLUE}Checking for stub-function clippy-allow signature...${NC}"
# shellcheck disable=SC2086
if rg_capture "stub-function signature" "$SCAN_TMP/stub-signatures" -U --multiline '#\[allow\([^)]*(unused_self[^)]*unnecessary_wraps|unnecessary_wraps[^)]*unused_self)' $SRC_PATHS --count; then
    STUB_SIGNATURE_FNS=$(sum_counts "$SCAN_TMP/stub-signatures")
    if [ "${STUB_SIGNATURE_FNS:-0}" -gt 0 ]; then
        fail_validation "Found $STUB_SIGNATURE_FNS stub-disguise function(s) (unused_self + unnecessary_wraps)"
        rg -U --multiline '#\[allow\([^)]*(unused_self[^)]*unnecessary_wraps|unnecessary_wraps[^)]*unused_self)' $SRC_PATHS -n 2>/dev/null | head -5
    else
        pass_validation "No stub-function signatures"
    fi
fi

# ============================================================================
# #[cfg(test)] in src (warning by default, error if local config enforces it)
# ============================================================================
echo -e "${BLUE}Checking for inline test modules...${NC}"
ENFORCE_NO_CFG_TEST=$(grep "enforce_no_cfg_test.*true" "$LOCAL_PATTERNS_FILE" 2>/dev/null | wc -l | tr -d ' ')
# shellcheck disable=SC2086
if rg_capture "inline test module" "$SCAN_TMP/cfg-test" "#\[cfg\(test\)\]" $SRC_PATHS --count; then
    CFG_TEST=$(sum_counts "$SCAN_TMP/cfg-test")
    if [ "$CFG_TEST" -gt 0 ]; then
        if [ "${ENFORCE_NO_CFG_TEST:-0}" -gt 0 ]; then
            fail_validation "Found $CFG_TEST #[cfg(test)] in src/ — tests go in external tests/ directory"
        else
            warn_validation "Found $CFG_TEST #[cfg(test)] in src/ (unit tests; the src/ scans above skip a trailing test module)"
        fi
    else
        pass_validation "No inline test modules"
    fi
fi

# ============================================================================
# Test module layout (warning by default, error if local config enforces it)
# ============================================================================
# The unwrap/expect/panic/mock/underscore scans skip a file's trailing
# `#[cfg(test)] mod tests { ... }`. A layout that filter would misread — an item
# after the test module, a test-only fn outside one — could hide production
# code from those scans, so it is reported here. A repo fails on it by setting
# `enforce_layout = true` under [test_modules] in validation-patterns.local.toml.
echo -e "${BLUE}Checking test module layout...${NC}"
# Run before the scans (see MISREAD_FILES); reported here.
LAYOUT_COUNT=$(printf '%s\n' "$LAYOUT_ERRORS" | grep -c . || true)
ENFORCE_LAYOUT=$(grep -E "^[[:space:]]*enforce_layout[[:space:]]*=[[:space:]]*true" "$LOCAL_PATTERNS_FILE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$LAYOUT_RC" -gt 1 ]; then
    fail_validation "The test module layout check could not run (exit $LAYOUT_RC) — no file's layout is known"
    sed 's/^/   /' "$SCAN_TMP/layout.err" | head -5
elif [ "${LAYOUT_COUNT:-0}" -gt 0 ]; then
    if [ "${ENFORCE_LAYOUT:-0}" -gt 0 ]; then
        fail_validation "Found $LAYOUT_COUNT test module layout problem(s) — the test module must be a trailing inline mod"
    else
        warn_validation "Found $LAYOUT_COUNT test module layout problem(s) — those files were scanned whole, test module included"
    fi
    printf '%s\n' "$LAYOUT_ERRORS" | head -5
else
    pass_validation "Test modules are trailing inline modules"
fi

# ============================================================================
# Temporary solutions
# ============================================================================
echo -e "${BLUE}Checking for temporary solutions...${NC}"
# shellcheck disable=SC2086
if rg_capture "temporary solution" "$SCAN_TMP/temp" "\\bhack\\b|\\bworkaround\\b|\\bquick.*fix\\b|future.*implementation|temporary.*solution|\\btemp\\b.*\\bfix\\b" $SRC_PATHS --count-matches; then
    TEMP=$(sum_counts "$SCAN_TMP/temp")
    if [ "${TEMP:-0}" -gt 0 ]; then
        fail_validation "Found $TEMP temporary solution markers"
    else
        pass_validation "No temporary solutions"
    fi
fi

# ============================================================================
# Empty source modules
# ============================================================================
echo -e "${BLUE}Checking for empty source modules...${NC}"
EMPTY_MODULES=0
EMPTY_SCANNED=true
# shellcheck disable=SC2086
while IFS= read -r rs_file; do
    # Any visibility — pub, pub(crate), pub(super), pub(in path) — and any
    # async/unsafe/extern qualifier before the item keyword counts as a declaration.
    # A crashed rg here used to read as "0 declarations" and blame the file.
    if ! rg_capture "empty module" "$SCAN_TMP/decls" "^(pub(\([^)]*\))? )?(async )?(unsafe )?(extern \"[^\"]*\" )?(fn |struct |enum |impl |const |static |type |trait |macro|mod |use )" "$rs_file" --count; then
        EMPTY_SCANNED=false
        break
    fi
    DECL_COUNT=$(sum_counts "$SCAN_TMP/decls")
    if [ "$DECL_COUNT" -eq 0 ]; then
        EMPTY_MODULES=$((EMPTY_MODULES + 1))
        echo "  Empty: $rs_file"
    fi
done < <(find $SRC_PATHS -name "*.rs" -not -path "*/tests/*" -not -path "*/bin/*" 2>/dev/null)
if [ "$EMPTY_SCANNED" = true ]; then
    if [ "$EMPTY_MODULES" -gt 0 ]; then
        fail_validation "Found $EMPTY_MODULES empty source modules"
    else
        pass_validation "No empty source modules"
    fi
fi

# ============================================================================
# Test integrity: ignored tests
# ============================================================================
echo -e "${BLUE}Checking test integrity...${NC}"
# shellcheck disable=SC2086
if [ -n "$TEST_PATHS" ] && rg_capture "ignored test" "$SCAN_TMP/ignored" '#\[ignore' $TEST_PATHS --count; then
    IGNORED_TESTS=$(sum_counts "$SCAN_TMP/ignored")
    # Check allowlist
    ALLOWED_IGNORED=0
    ALLOWLIST_SCANNED=true
    if [ -f "$PROJECT_ROOT/ignored-tests-allowlist.toml" ]; then
        ALLOWLIST_FILES=$(python3 -c "
import tomllib
with open('$PROJECT_ROOT/ignored-tests-allowlist.toml', 'rb') as f:
    config = tomllib.load(f)
print(' '.join(config.get('files', [])))
" 2>/dev/null || echo "")
        if [ -n "$ALLOWLIST_FILES" ]; then
            for f in $ALLOWLIST_FILES; do
                # A listed file that is gone allows nothing, as before; one rg cannot read fails.
                [ -e "$f" ] || continue
                if ! rg_capture "ignored-test allowlist" "$SCAN_TMP/allowed" '#\[ignore' "$f" -c; then
                    ALLOWLIST_SCANNED=false
                    break
                fi
                COUNT=$(sum_counts "$SCAN_TMP/allowed")
                ALLOWED_IGNORED=$((ALLOWED_IGNORED + COUNT))
            done
        fi
    fi
    UNAUTHORIZED=$((IGNORED_TESTS - ALLOWED_IGNORED))
    if [ "$ALLOWLIST_SCANNED" = false ]; then
        fail_validation "the ignored-test allowlist could not be counted — the ignored-test scan was not checked"
    elif [ "$UNAUTHORIZED" -gt 0 ]; then
        fail_validation "Found $UNAUTHORIZED unauthorized ignored tests (total: $IGNORED_TESTS, allowed: $ALLOWED_IGNORED)"
    else
        if [ "$IGNORED_TESTS" -gt 0 ]; then
            pass_validation "All $IGNORED_TESTS ignored tests are in allowlist"
        else
            pass_validation "No ignored tests"
        fi
    fi
fi

# ============================================================================
# One integration-test binary per crate (error if local config enforces it)
# ============================================================================
# Every top-level tests/*.rs is a binary of its own, each linked against the whole
# dependency graph: dravr-platform's 793 of them took 84 GiB and a 13-minute suite, and
# one binary takes ~415 MB and ~4 minutes. A crate's integration tests are the modules
# of tests/it/main.rs. A top-level file is kept only for a suite that writes the process
# environment, because the tests of one binary share one environment; for the same
# reason nothing under tests/it/ may write it. A crate with `autotests = false` declares
# its binaries as [[test]] entries, so its top-level files are not counted. A repo fails
# on the layout by setting `one_binary = true` under [test_layout] in
# validation-patterns.local.toml; otherwise the scan prints each crate's binary count.
echo -e "${BLUE}Checking integration test binaries...${NC}"
ONE_BINARY=$(grep -E "^[[:space:]]*one_binary[[:space:]]*=[[:space:]]*true" "$LOCAL_PATTERNS_FILE" 2>/dev/null | wc -l | tr -d ' ')
# A call, not a mention: a doc comment naming the function writes nothing. The brackets
# keep this line from matching itself.
ENV_WRITE='\b(se[t]|remov[e])_var\s*\('
TEST_CRATES="$SCAN_TMP/test-crates"
BIN_PROBLEMS="$SCAN_TMP/bin-problems"
: >"$BIN_PROBLEMS"
{
    if [ -d "$PROJECT_ROOT/tests" ]; then printf '%s\n' "$PROJECT_ROOT"; fi
    for crate_dir in "$PROJECT_ROOT"/crates/*/; do
        if [ -d "${crate_dir}tests" ]; then printf '%s\n' "${crate_dir%/}"; fi
    done
} >"$TEST_CRATES"
BIN_SCANNED=true
BIN_COUNTS=""
while IFS= read -r crate; do
    if [ "$crate" = "$PROJECT_ROOT" ]; then crate_label=$(basename "$PROJECT_ROOT"); else crate_label=${crate##*/}; fi
    autotests_rc=1
    if [ -f "$crate/Cargo.toml" ]; then
        autotests_rc=0
        grep -qE '^[[:space:]]*autotests[[:space:]]*=[[:space:]]*false' "$crate/Cargo.toml" || autotests_rc=$?
        if [ "$autotests_rc" -gt 1 ]; then
            fail_validation "could not read $crate_label/Cargo.toml — the test binary scan was not checked"
            BIN_SCANNED=false
            break
        fi
    fi
    binaries=0
    if [ "$autotests_rc" -eq 0 ]; then
        binaries=$(awk '/^[[:space:]]*\[\[test\]\]/ { n++ } END { print n + 0 }' "$crate/Cargo.toml")
    else
        if ! find "$crate/tests" -maxdepth 1 -type f -name '*.rs' >"$SCAN_TMP/bin-top" 2>"$SCAN_TMP/bin-top.err"; then
            fail_validation "could not list $crate_label/tests — the test binary scan was not checked"
            sed 's/^/   /' "$SCAN_TMP/bin-top.err" | head -5
            BIN_SCANNED=false
            break
        fi
        while IFS= read -r top_file; do
            binaries=$((binaries + 1))
            if ! rg_capture "test environment-write" "$SCAN_TMP/bin-env" -l "$ENV_WRITE" "$top_file"; then
                BIN_SCANNED=false
                break 2
            fi
            if [ "$(count_lines "$SCAN_TMP/bin-env")" -eq 0 ]; then
                echo "${top_file#"$PROJECT_ROOT"/}: a test binary of its own that writes no environment — make it a module of tests/it/main.rs" >>"$BIN_PROBLEMS"
            fi
        done < "$SCAN_TMP/bin-top"
        if [ -f "$crate/tests/it/main.rs" ]; then binaries=$((binaries + 1)); fi
    fi
    if [ -d "$crate/tests/it" ]; then
        if ! rg_capture "test environment-write" "$SCAN_TMP/bin-env-it" -l --glob '*.rs' "$ENV_WRITE" "$crate/tests/it"; then
            BIN_SCANNED=false
            break
        fi
        while IFS= read -r it_file; do
            echo "${it_file#"$PROJECT_ROOT"/}: writes the process environment inside the shared tests/it binary — give it a top-level tests/<suite>.rs of its own" >>"$BIN_PROBLEMS"
        done < "$SCAN_TMP/bin-env-it"
    fi
    BIN_COUNTS="$BIN_COUNTS $crate_label=$binaries"
done < "$TEST_CRATES"
if [ "$BIN_SCANNED" = true ] && [ -n "$BIN_COUNTS" ]; then
    BIN_PROBLEM_COUNT=$(count_lines "$BIN_PROBLEMS")
    if [ "${ONE_BINARY:-0}" -gt 0 ]; then
        if [ "$BIN_PROBLEM_COUNT" -gt 0 ]; then
            fail_validation "Found $BIN_PROBLEM_COUNT test file(s) outside one test binary per crate — suites are modules of tests/it/main.rs"
            sed 's/^/   /' "$BIN_PROBLEMS" | head -20
        else
            pass_validation "One integration test binary per crate"
        fi
    else
        echo "ℹ️  Integration test binaries per crate:$BIN_COUNTS (one per crate is enforced by [test_layout] one_binary = true)"
    fi
fi

# ============================================================================
# CI continue-on-error
# ============================================================================
if [ -d "$PROJECT_ROOT/.github/workflows" ]; then
    echo -e "${BLUE}Checking CI integrity...${NC}"
    # Count continue-on-error, excluding comments and excluded workflows
    COE_EXCLUDES=""
    if [ -f "$LOCAL_PATTERNS_FILE" ]; then
        COE_EXCLUDES=$(grep "exclude_workflows" "$LOCAL_PATTERNS_FILE" 2>/dev/null | sed 's/.*\[//' | sed 's/\]//' | tr -d '"' | tr ',' '\n' | sed 's/^ //' || echo "")
    fi
    if rg_capture "continue-on-error" "$SCAN_TMP/coe" "continue-on-error: true" "$PROJECT_ROOT/.github/workflows/"; then
        COE_RESULT=$(grep -v "#.*continue-on-error" "$SCAN_TMP/coe" || true)
        for excl in $COE_EXCLUDES; do
            COE_RESULT=$(echo "$COE_RESULT" | grep -v "$excl" || true)
        done
        # `grep -c` prints 0 and exits 1 when nothing matches, so `|| echo 0` used to
        # append a second 0 and the test saw "0\n0" -> "integer expression expected".
        # It fell through to the pass branch, so it failed safe, but it printed an
        # error on every clean run in every repo.
        COE=$(printf '%s\n' "$COE_RESULT" | grep -c "continue-on-error" || true)
        if [ "$COE" -gt 0 ]; then
            fail_validation "Found $COE continue-on-error: true in CI workflows"
        else
            pass_validation "No continue-on-error in CI"
        fi
    fi
fi

# ============================================================================
# JS/TS test integrity (if frontend exists)
# ============================================================================
FRONTEND_PATHS=""
[ -d "$PROJECT_ROOT/frontend" ] && FRONTEND_PATHS="$FRONTEND_PATHS $PROJECT_ROOT/frontend/"
[ -d "$PROJECT_ROOT/sdk" ] && FRONTEND_PATHS="$FRONTEND_PATHS $PROJECT_ROOT/sdk/"
[ -d "$PROJECT_ROOT/frontend-mobile" ] && FRONTEND_PATHS="$FRONTEND_PATHS $PROJECT_ROOT/frontend-mobile/"

if [ -n "$FRONTEND_PATHS" ]; then
    echo -e "${BLUE}Checking JS/TS test integrity...${NC}"
    # shellcheck disable=SC2086
    if rg_capture "skipped JS/TS test" "$SCAN_TMP/js-skips" "\\.skip\\(|xit\\(|xdescribe\\(|test\\.skip\\(" $FRONTEND_PATHS -g "*.test.*" -g "*.spec.*" --count; then
        JS_SKIPS=$(sum_counts "$SCAN_TMP/js-skips")
        if [ "${JS_SKIPS:-0}" -gt 0 ]; then
            fail_validation "Found $JS_SKIPS skipped JS/TS tests"
        else
            pass_validation "No skipped JS/TS tests"
        fi
    fi
    # A test body that announces a harness instead of asserting anything.
    # shellcheck disable=SC2086
    if rg_capture "placeholder JS/TS test" "$SCAN_TMP/js-placeholders" "In a full E2E test, we would|testing infrastructure ready|testing ready|validation infrastructure ready" $FRONTEND_PATHS -g "*.test.*" -g "*.spec.*" --count; then
        JS_PLACEHOLDER_TESTS=$(sum_counts "$SCAN_TMP/js-placeholders")
        if [ "${JS_PLACEHOLDER_TESTS:-0}" -gt 0 ]; then
            fail_validation "Found $JS_PLACEHOLDER_TESTS placeholder JS/TS test bodies"
            rg -n "In a full E2E test, we would|testing infrastructure ready|testing ready|validation infrastructure ready" $FRONTEND_PATHS -g "*.test.*" -g "*.spec.*" 2>/dev/null | head -5
        else
            pass_validation "No placeholder JS/TS test bodies"
        fi
    fi
fi

# ============================================================================
# Route file size check (prevent business logic in HTTP handlers)
# ============================================================================
ROUTE_PATHS=$(find $SRC_PATHS -path "*/routes/*.rs" -not -name "mod.rs" 2>/dev/null)
if [ -n "$ROUTE_PATHS" ]; then
    echo -e "${BLUE}Checking route file sizes...${NC}"
    ENFORCE_ROUTE_SIZE=$(grep "enforce_route_size_limit.*true" "$LOCAL_PATTERNS_FILE" 2>/dev/null | wc -l | tr -d ' ')
    OVERSIZED=0
    for route_file in $ROUTE_PATHS; do
        LINES=$(wc -l < "$route_file" | tr -d ' ')
        if [ "$LINES" -gt 500 ]; then
            OVERSIZED=$((OVERSIZED + 1))
            SHORT=$(echo "$route_file" | sed "s|.*/routes/|routes/|")
            if [ "${ENFORCE_ROUTE_SIZE:-0}" -gt 0 ]; then
                fail_validation "Route $SHORT is $LINES lines — extract business logic to services/"
            else
                warn_validation "Route $SHORT is $LINES lines — consider extracting business logic to services/"
            fi
        fi
    done
    if [ "$OVERSIZED" -eq 0 ]; then
        pass_validation "All route files under 500 lines"
    fi
fi

# ============================================================================
# Limitation register gates (llm-registre, vendored as a submodule)
# ============================================================================
# Deferral prose ban + LIMITATION(marker#n) format + dark-launch ledger format.
# The tool is Apache-2.0 and lives at github.com/dravr-ai/llm-registre; each
# repo points it at a tracker via its own registre.toml. Consumers check out
# submodules recursively, so a missing vendor/ dir means an incomplete clone —
# warn rather than fail, exactly like the other optional tiers here.
LIMITATION_GATES="$SCRIPT_DIR/../vendor/llm-registre/limitation-gates.sh"
LIMITATION_SCAN_DIRS=""
# A repo that declares scan_dirs in registre.toml owns its scope: the gate reads it when handed no
# directories, and so does every other tool that asks it for --list-files. Only a repo that
# declares nothing gets this default.
REGISTRE_DECLARES_SCOPE=false
grep -qE '^[[:space:]]*scan_dirs[[:space:]]*=' "$PROJECT_ROOT/registre.toml" 2>/dev/null \
    && REGISTRE_DECLARES_SCOPE=true
if [ "$REGISTRE_DECLARES_SCOPE" = false ]; then
    [ -d "$PROJECT_ROOT/crates" ] && LIMITATION_SCAN_DIRS="$LIMITATION_SCAN_DIRS crates"
    [ -d "$PROJECT_ROOT/src" ] && LIMITATION_SCAN_DIRS="$LIMITATION_SCAN_DIRS src"
fi
if [ ! -x "$LIMITATION_GATES" ]; then
    warn_validation "llm-registre not checked out — run: git submodule update --init --recursive"
elif [ "$REGISTRE_DECLARES_SCOPE" = true ] || [ -n "$LIMITATION_SCAN_DIRS" ]; then
    # Word-splitting of the dir list is intentional.
    # shellcheck disable=SC2086
    if ! (cd "$PROJECT_ROOT" && "$LIMITATION_GATES" $LIMITATION_SCAN_DIRS); then
        VALIDATION_FAILED=true
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${BLUE}==== Architectural Validation Summary ====${NC}"
if [ "$VALIDATION_FAILED" = true ]; then
    echo -e "${RED}❌ Architectural validation FAILED${NC}"
    echo -e "${RED}Fix critical issues above before deployment${NC}"
    exit 1
else
    echo -e "${GREEN}✅ All architectural validations passed${NC}"
fi
