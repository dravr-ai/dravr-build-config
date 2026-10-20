#!/usr/bin/env bash
# ABOUTME: Fixture test for validate.sh's own rules — each scan fails the repo that breaks it and names the file
# ABOUTME: Pins the rules carried over from patterns.toml and that every counted scan fails closed when rg or a filter cannot run
#
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="${VALIDATE:-$SCRIPT_DIR/validate.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
passes=0
pass() { echo "  ✅ $1"; passes=$((passes + 1)); }
fail() { echo "  ❌ $1"; failures=$((failures + 1)); }

# fixture <name> — stdin is crates/demo/src/lib.rs; prints the repo root
fixture() {
  mkdir -p "$WORK/$1/crates/demo/src"
  cat >"$WORK/$1/crates/demo/src/lib.rs"
  printf '%s\n' "$WORK/$1"
}
# validate_exit <root> — runs $VALIDATE there, output in $WORK/out
validate_exit() {
  local root=$1 code=0
  ( cd "$root" && PROJECT_ROOT="$root" bash "$VALIDATE" >"$WORK/out" 2>&1 </dev/null ) || code=$?
  echo "$code"
}
plain() { sed 's/\x1b\[[0-9;]*m//g' "$WORK/out"; }

echo "validate.sh fixture tests"

repo="$(fixture clean <<'EOF'
pub fn double(n: u32) -> u32 {
    n * 2
}
EOF
)"
if [ "$(validate_exit "$repo")" = "0" ] && plain | grep -q 'All architectural validations passed'; then pass "a clean crate passes"; else fail "a clean crate did not pass: $(plain | grep '❌' || true)"; fi

# carnet#942: anyhow::Result needs no `use anyhow` line, and patterns.toml listed it while
# nothing read the file.
repo="$(fixture anyhow-type <<'EOF'
pub fn f() -> anyhow::Result<()> {
    Ok(())
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && plain | grep -q 'anyhow usages' && plain | grep -q 'crates/demo/src/lib.rs'; then
  pass "a fully qualified anyhow::Result fails and names the file"
else
  fail "a fully qualified anyhow::Result passed: $(plain | grep -E '❌|✅ No anyhow' || true)"
fi

repo="$(fixture dummy <<'EOF'
pub fn f() -> u32 {
    // dummy implementation
    0
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && plain | grep -q 'placeholder implementations' && plain | grep -q 'crates/demo/src/lib.rs'; then
  pass "a dummy implementation fails and names the file"
else
  fail "a dummy implementation passed: $(plain | grep -E 'placeholder' || true)"
fi

repo="$(fixture opening <<'EOF'
pub fn f() -> u32 {
    // Implementation would go here once the API settles.
    0
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && plain | grep -q 'placeholder implementations'; then
  pass "a sentence opening 'Implementation would' fails"
else
  fail "'Implementation would' passed"
fi

repo="$(fixture prose <<'EOF'
/// Keeping a second implementation would mean a fix lands twice; callers should implement
/// the trait themselves. The {{PLACEHOLDER}} token is replaced at render time.
pub fn f() -> u32 {
    0
}
EOF
)"
if [ "$(validate_exit "$repo")" = "0" ]; then
  pass "lower-case prose and a template PLACEHOLDER token pass"
else
  fail "ordinary prose failed the placeholder rule: $(plain | grep -A3 'placeholder' || true)"
fi

# carnet#941: the src/ scans pipe rg through test-module-lines.sh. A filter that cannot
# run read as a clean tree, so it now fails the validation. validate.sh finds the filter
# beside itself, so a copy beside a filter that cannot execute is the broken install.
mkdir -p "$WORK/broken-install"
cp "$VALIDATE" "$WORK/broken-install/validate.sh"
printf '#!/bin/sh\nexit 0\n' >"$WORK/broken-install/test-module-lines.sh"
chmod -x "$WORK/broken-install/test-module-lines.sh"
repo="$(fixture filter-broken <<'EOF'
pub fn f(x: Option<u8>) -> u8 {
    x.unwrap()
}
EOF
)"
if [ "$(VALIDATE="$WORK/broken-install/validate.sh" validate_exit "$repo")" = "1" ] && plain | grep -q 'test-module filter failed'; then
  pass "a test-module filter that cannot run fails the validation"
else
  fail "a broken filter read as clean: $(plain | grep -E '❌|✅ No problematic|All architectural' || true)"
fi
if ! plain | grep -q 'No problematic error handling'; then
  pass "and no scan that depended on it reports a pass"
else
  fail "a scan reported a pass through a broken filter"
fi

# carnet#927: the steps around the filter fail closed too. A shim that crashes one tool
# on one call, and runs the real one otherwise, stands in for a mawk or rg that dies.
# shim <dir> <tool> <case-pattern on "$*"> — a PATH entry whose <tool> exits 2 on a match
shim() {
  local dir="$WORK/$1" real
  real="$(command -v "$2")"
  mkdir -p "$dir"
  printf '#!/bin/bash\ncase "$*" in %s) echo "%s: simulated crash" >&2; exit 2;; esac\nexec %s "$@"\n' "$3" "$2" "$real" >"$dir/$2"
  chmod +x "$dir/$2"
  printf '%s\n' "$dir"
}
repo="$(fixture unwrap-in-prod <<'EOF'
pub fn f(x: Option<u8>) -> u8 {
    x.unwrap()
}
EOF
)"
# The split of the matches by test-module layout: a crash left the filter an empty file.
dir="$(shim awk-split awk "*'!(\$1 in misread)'*")"
if [ "$(PATH="$dir:$PATH" validate_exit "$repo")" = "1" ] && plain | grep -q 'could not split' && ! plain | grep -q 'No problematic error handling'; then
  pass "a layout split that cannot run fails the validation and reports no pass"
else
  fail "a crashed layout split read as clean: $(plain | grep -E '❌|✅ No problematic|All architectural' || true)"
fi
# The exemption filter: `{ rg -v … || true; }` read a crash as every line exempted.
dir="$(shim rg-exempt rg "-v*")"
if [ "$(PATH="$dir:$PATH" validate_exit "$repo")" = "1" ] && plain | grep -q 'exemption filter could not run' && ! plain | grep -q 'No problematic error handling'; then
  pass "an exemption filter that cannot run fails the validation and reports no pass"
else
  fail "a crashed exemption filter read as clean: $(plain | grep -E '❌|✅ No problematic|All architectural' || true)"
fi
if plain | grep -q 'mock comment filter could not run' && plain | grep -q 'guard-binding filter could not run'; then
  pass "and the mock and underscore-name scans fail on it too"
else
  fail "the mock or underscore-name scan passed through a crashed filter: $(plain | grep -E 'mock|underscore' || true)"
fi

# carnet#1093: the counted scans outside src/'s production split read `rg … 2>/dev/null`,
# so an rg that crashed on one of them counted zero and printed a pass. A repo that
# reaches every scan — tests/ with an allowlisted #[ignore], CI workflows, a frontend —
# passes whole; then each scan's rg alone is crashed, and that scan must fail by name.
repo="$(fixture every-scan <<'EOF'
pub fn double(n: u32) -> u32 {
    n * 2
}
EOF
)"
mkdir -p "$repo/crates/demo/tests" "$repo/.github/workflows" "$repo/frontend"
printf '#[ignore]\n#[test]\nfn slow() {}\n' >"$repo/crates/demo/tests/slow.rs"
printf 'files = ["crates/demo/tests/slow.rs"]\n' >"$repo/ignored-tests-allowlist.toml"
printf 'on: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' >"$repo/.github/workflows/ci.yml"
printf 'it("adds", () => expect(1 + 1).toBe(2));\n' >"$repo/frontend/add.test.ts"
if [ "$(validate_exit "$repo")" = "0" ] && plain | grep -q 'All 1 ignored tests are in allowlist' && plain | grep -q 'No skipped JS/TS tests'; then
  pass "a repo that reaches every counted scan passes"
else
  fail "the every-scan repo did not pass: $(plain | grep -E '❌' || true)"
fi
# <label>@<case pattern on rg's "$*">@<the scan's own pass line, an ERE> (rg patterns hold `|`).
# The unwrap scan still passing proves the shim crashed that one call, not every rg.
while IFS='@' read -r label pattern verdict; do
  dir="$(shim "rg-crash-${label// /-}" rg "$pattern")"
  if [ "$(PATH="$dir:$PATH" validate_exit "$repo")" = "1" ] && plain | grep -q "rg could not run the $label scan" && ! plain | grep -qE "✅ $verdict" &&
     plain | grep -q '✅ No problematic error handling'; then
    pass "a crashed rg fails the $label scan and reports no pass"
  else
    fail "a crashed rg read as clean in the $label scan: $(plain | grep -E "❌|✅ $verdict" || true)"
  fi
done <<'EOF'
placeholder@*'stub for now'*@No placeholder implementations
anyhow macro@*'anyhow!'*@No anyhow usage
anyhow import@'use anyhow::'*@No anyhow usage
anyhow type@'anyhow::(Result'*@No anyhow usage
TODO marker@*FIXME*/src/*@No incomplete code markers
TODO marker (tests)@*FIXME*/tests/*@No incomplete code markers
clippy allow@*'[^)]*\)\]'*@No unauthorized clippy allows
dead code@*dead_code*@No dead code annotations
stub-function signature@*unnecessary_wraps*@No stub-function signatures
inline test module@'#\[cfg\(test\)\] '*@No inline test modules
temporary solution@*workaround*@No temporary solutions
empty module@*'(fn |struct'*@No empty source modules
ignored test@'#\[ignore'*--count@(No|All [0-9]+) ignored tests
ignored-test allowlist@'#\[ignore'*-c@(No|All [0-9]+) ignored tests
continue-on-error@*continue-on-error*@No continue-on-error
skipped JS/TS test@*xdescribe*@No skipped JS/TS tests
placeholder JS/TS test@*'infrastructure ready'*@No placeholder JS/TS test bodies
EOF

# The clippy-allow scan read only the `#[allow(` prefix of each match, so no lint name
# ever reached the allowlist; an allowed lint beside a forbidden one must still pass.
repo="$(fixture clippy-allow <<'EOF'
#[allow(clippy::too_many_lines, clippy::unwrap_used)]
pub fn f() -> u32 {
    0
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && plain | grep -q 'Found 1 unauthorized #\[allow(clippy::)\]' && plain | grep -q 'crates/demo/src/lib.rs'; then
  pass "a forbidden clippy allow beside an allowed one fails and names the file"
else
  fail "a forbidden clippy allow passed: $(plain | grep -E 'clippy' || true)"
fi

# rustfmt wraps a long allow over several lines; the single-line match read it as no
# allow at all (carnet#1094). Each wrapped attribute is one finding, named by its file.
repo="$(fixture clippy-allow-wrapped <<'EOF'
#[allow(
    clippy::too_many_lines,
    clippy::unwrap_used,
    clippy::expect_used
)]
pub fn f() -> u32 {
    0
}

#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn g() -> u32 {
    0
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && plain | grep -q 'Found 2 unauthorized #\[allow(clippy::)\]' && plain | grep -q 'crates/demo/src/lib.rs:1:'; then
  pass "a wrapped forbidden clippy allow fails, counting each lint, and names the file"
else
  fail "a wrapped forbidden clippy allow passed: $(plain | grep -E 'clippy' || true)"
fi

repo="$(fixture dead-code-wrapped <<'EOF'
#[allow(
    clippy::too_many_lines,
    dead_code
)]
pub fn f() -> u32 {
    0
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && plain | grep -q 'Found 1 #\[allow(dead_code)\]'; then
  pass "a wrapped dead_code allow fails"
else
  fail "a wrapped dead_code allow passed: $(plain | grep -E 'dead' || true)"
fi

# A crate with no tests/ directory: the unmatched crates/*/tests/ glob is not handed to
# rg as a literal path, which rg would now report as a failed search. The test scans are
# skipped, as for a repo with no tests at all; they used to print a pass over that crash.
repo="$(fixture no-tests-dir <<'EOF'
pub fn double(n: u32) -> u32 {
    n * 2
}
EOF
)"
if [ "$(validate_exit "$repo")" = "0" ] && ! plain | grep -q 'rg could not run' && ! plain | grep -q 'No ignored tests'; then
  pass "a crate without a tests/ directory still passes"
else
  fail "a crate without tests/ failed: $(plain | grep -E '❌' || true)"
fi

# A test module that is not the last item: the filter would hide everything after it,
# so a file --check flags is scanned whole and the production code below still counts.
repo="$(fixture misread <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn t() {}
}

pub fn after() -> u32 {
    let _unused = mock_value();
    2
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && plain | grep -q 'underscore-prefixed names' && plain | grep -q 'mock/stub patterns' && plain | grep -q 'crates/demo/src/lib.rs:8:'; then
  pass "production code after a misplaced test module still fails, naming the file and line"
else
  fail "code after a misplaced test module was hidden: $(plain | grep -E '❌|✅ No (production|underscore)' || true)"
fi

if [ "$failures" -gt 0 ]; then
  echo "validate.sh: $passes passed · $failures failed"
  exit 1
fi
echo "validate.sh: $passes passed · 0 failed"
