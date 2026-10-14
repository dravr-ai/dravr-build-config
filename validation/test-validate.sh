#!/usr/bin/env bash
# ABOUTME: Fixture test for validate.sh's own rules — each scan fails the repo that breaks it and names the file
# ABOUTME: Pins the anyhow and placeholder rules carried over from the deleted patterns.toml
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
# validate_exit <root> [env…] — runs validate.sh there, output in $WORK/out
validate_exit() {
  local root=$1 code=0
  shift
  ( cd "$root" && env "$@" PROJECT_ROOT="$root" bash "$VALIDATE" >"$WORK/out" 2>&1 </dev/null ) || code=$?
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

if [ "$failures" -gt 0 ]; then
  echo "validate.sh: $passes passed · $failures failed"
  exit 1
fi
echo "validate.sh: $passes passed · 0 failed"
