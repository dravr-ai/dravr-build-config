#!/usr/bin/env bash
# ABOUTME: Fixture test for test-module-lines.sh — the filter drops only a trailing test module's lines
# ABOUTME: Pins that a production unwrap is kept, a test-module unwrap is dropped, and --check rejects every layout the filter would misread
#
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNDER_TEST="${UNDER_TEST:-$SCRIPT_DIR/test-module-lines.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; failures=$((failures + 1)); }

write() { # $1 = relative path, stdin = body
  mkdir -p "$(dirname "$WORK/$1")"
  cat >"$WORK/$1"
}

# Matches of `.unwrap()` that survive the filter, counted.
surviving_unwraps() {
  ( cd "$WORK" && { rg -n --with-filename '\.unwrap\(\)' "$1" || true; } | "$UNDER_TEST" | wc -l | tr -d ' ' )
}

check_exit() {
  local code=0
  ( cd "$WORK" && "$UNDER_TEST" --check "$1" >"$WORK/out" 2>&1 ) || code=$?
  echo "$code"
}

echo "test-module-lines.sh fixture tests"

write good/src/lib.rs <<'EOF'
pub fn parse(s: &str) -> Option<u32> {
    s.parse().ok().map(|n: u32| n + Some(1).unwrap())
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn parses() {
        assert_eq!(parse("1").unwrap(), 2);
    }
}
EOF
got="$(surviving_unwraps good/src/lib.rs)"
if [ "$got" = "1" ]; then pass "the production unwrap is kept and the test-module unwrap is dropped"; else fail "expected 1 surviving unwrap, got $got"; fi
if [ "$(check_exit good/src)" = "0" ]; then pass "--check accepts a trailing inline test module"; else fail "--check rejected a trailing inline test module: $(cat "$WORK/out")"; fi

write attr/src/lib.rs <<'EOF'
#[cfg(test)]
#[allow(clippy::too_many_lines)]
pub(crate) mod tests {
    fn f() { Some(1).unwrap(); }
}
EOF
got="$(surviving_unwraps attr/src/lib.rs)"
if [ "$got" = "0" ]; then pass "attributes between #[cfg(test)] and the module are skipped"; else fail "expected 0 surviving unwraps, got $got"; fi

write multiattr/src/lib.rs <<'EOF'
pub fn prod() -> u32 {
    2
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
)]
mod tests {
    #[test]
    fn t() {
        let raw = r#"{
"a": 1
}"#;
        assert_eq!(Some(raw.len()).unwrap(), 12);
    }
}

#[cfg(test)]
mod more_tests {
    #[test]
    fn u() {
        assert_eq!(Some(1).unwrap(), 1);
    }
}
EOF
got="$(surviving_unwraps multiattr/src/lib.rs)"
if [ "$got" = "0" ]; then pass "a multi-line attribute before the test module is skipped"; else fail "expected 0 surviving unwraps, got $got"; fi
if [ "$(check_exit multiattr/src)" = "0" ]; then pass "--check accepts a multi-line attribute, a column-0 raw string and two trailing test modules"; else fail "--check rejected a valid layout: $(cat "$WORK/out")"; fi

write fn/src/lib.rs <<'EOF'
#[cfg(test)]
fn helper() -> u32 { Some(1).unwrap() }

pub fn prod() -> u32 { Some(2).unwrap() }
EOF
got="$(surviving_unwraps fn/src/lib.rs)"
if [ "$got" = "2" ]; then pass "a #[cfg(test)] on a fn strips nothing"; else fail "expected 2 surviving unwraps, got $got"; fi
if [ "$(check_exit fn/src)" = "1" ] && grep -q 'must open an inline' "$WORK/out"; then pass "--check rejects a test-only fn outside a module"; else fail "--check accepted a test-only fn: $(cat "$WORK/out")"; fi

write after/src/lib.rs <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn t() {}
}

pub fn after() -> u32 { Some(3).unwrap() }
EOF
if [ "$(check_exit after/src)" = "1" ] && grep -q 'after the test module' "$WORK/out"; then pass "--check rejects an item after the test module"; else fail "--check accepted an item after the test module: $(cat "$WORK/out")"; fi

write external/src/lib.rs <<'EOF'
#[cfg(test)]
mod tests;
EOF
if [ "$(check_exit external/src)" = "1" ]; then pass "--check rejects an out-of-line test module"; else fail "--check accepted mod tests;: $(cat "$WORK/out")"; fi

write indented/src/lib.rs <<'EOF'
pub struct S;
impl S {
    #[cfg(test)]
    fn t() -> u32 { Some(1).unwrap() }
}
EOF
got="$(surviving_unwraps indented/src/lib.rs)"
if [ "$got" = "1" ]; then pass "an indented #[cfg(test)] is scanned as production (fails loud)"; else fail "expected 1 surviving unwrap, got $got"; fi

if [ "$(check_exit missing/src)" = "2" ]; then pass "--check on a missing path fails instead of reading clean"; else fail "--check on a missing path did not exit 2"; fi

# End to end through validate.sh, the caller every consumer runs: a unit
# test's unwrap passes, the same call in production code fails, and a layout
# problem warns unless the repo opts in to enforce_layout.
VALIDATE="$SCRIPT_DIR/validate.sh"
validate_exit() { # $1 = fixture repo root
  local code=0
  ( cd "$1" && PROJECT_ROOT="$1" bash "$VALIDATE" >"$WORK/validate.out" 2>&1 </dev/null ) || code=$?
  echo "$code"
}
fixture_repo() { # $1 = name, stdin = crates/demo/src/lib.rs
  mkdir -p "$WORK/$1/crates/demo/src"
  cat >"$WORK/$1/crates/demo/src/lib.rs"
  printf '%s\n' "$WORK/$1"
}

repo="$(fixture_repo e2e-test-unwrap <<'EOF'
pub fn double(n: u32) -> u32 {
    n * 2
}

#[cfg(test)]
mod tests {
    use super::double;

    #[test]
    fn doubles() {
        let n: Option<u32> = Some(2);
        assert_eq!(double(n.unwrap()), 4);
        assert_eq!(double(n.expect("two")), 4);
        if n.is_none() {
            panic!("no value");
        }
    }
}
EOF
)"
if [ "$(validate_exit "$repo")" = "0" ]; then pass "validate.sh passes unwrap/expect/panic inside a trailing test module"; else fail "validate.sh failed a test-module unwrap: $(grep -E '❌' "$WORK/validate.out")"; fi

repo="$(fixture_repo e2e-prod-unwrap <<'EOF'
pub fn double(n: Option<u32>) -> u32 {
    n.unwrap() * 2
}
EOF
)"
if [ "$(validate_exit "$repo")" = "1" ] && grep -q 'problematic .unwrap()' "$WORK/validate.out"; then pass "validate.sh fails a production unwrap"; else fail "validate.sh passed a production unwrap"; fi

repo="$(fixture_repo e2e-layout <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn t() {}
}

pub fn after() -> u32 {
    2
}
EOF
)"
if [ "$(validate_exit "$repo")" = "0" ] && grep -q 'test module layout problem' "$WORK/validate.out"; then pass "a layout problem only warns by default"; else fail "a layout problem did not warn-and-pass by default"; fi
printf '[test_modules]\nenforce_layout = true\n' >"$repo/validation-patterns.local.toml"
if [ "$(validate_exit "$repo")" = "1" ]; then pass "enforce_layout = true turns a layout problem into a failure"; else fail "enforce_layout = true did not fail the layout problem"; fi

if [ "$failures" -gt 0 ]; then
  echo "test-module-lines.sh: $failures fixture(s) failed"
  exit 1
fi
echo "test-module-lines.sh: all fixtures passed"
