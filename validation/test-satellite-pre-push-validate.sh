#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Tests satellite-pre-push-validate.sh by making every tier fire on a throwaway cargo crate
# ABOUTME: Also proves hooks/pre-push accepts the marker it writes; no network, no dependencies

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/satellite-pre-push-validate.sh"
HOOK="$HERE/../hooks/pre-push"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
check(){ # <desc> <expected-status> <actual-status>
    [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected exit $2, got $3)"
}
says() { # <desc> <text> <fixed-string>
    printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1 — output lacks '$3': $(printf '%s' "$2" | tail -5)"
}

# Hermetic git: no global or system config, one identity for every commit.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[user]\n\tname = Ada Human\n\temail = ada@example.com\n' > "$GIT_CONFIG_GLOBAL"
export CARGO_TARGET_DIR="$TMP/target" CARGO_INCREMENTAL=0
unset SATELLITE_FEATURES PROJECT_ROOT

# --- a satellite-shaped crate: pinned toolchain, one feature, three tests ---
REPO="$TMP/sat"
mkdir -p "$REPO/src" "$REPO/tests" "$REPO/scripts/ci"
cd "$REPO" || exit 1
git init -q .
printf '[toolchain]\nchannel = "1.98.1"\ncomponents = ["clippy", "rustfmt"]\n' > rust-toolchain.toml
cat > Cargo.toml <<'EOF'
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"
publish = false

[features]
default = []
extra = []
EOF
cat > src/lib.rs <<'EOF'
// ABOUTME: Fixture library for the satellite pre-push gate test
// ABOUTME: Two plain functions and one behind the extra feature

/// Adds two numbers.
#[must_use]
pub const fn add(left: u32, right: u32) -> u32 {
    left + right
}

/// Doubles a number, only with the extra feature.
#[cfg(feature = "extra")]
#[must_use]
pub const fn double(value: u32) -> u32 {
    value * 2
}
EOF
cat > tests/add_test.rs <<'EOF'
// ABOUTME: Tests for the fixture library
// ABOUTME: Two always-on tests and one that needs the extra feature

#[test]
fn adds_small_numbers() {
    assert_eq!(fixture::add(2, 3), 5);
}

#[test]
fn adds_zero() {
    assert_eq!(fixture::add(7, 0), 7);
}

#[cfg(feature = "extra")]
#[test]
fn doubles() {
    assert_eq!(fixture::double(21), 42);
}
EOF
# The wrapper every satellite carries, pointing at this checkout's gate instead of .build.
cat > scripts/ci/pre-push-validate.sh <<EOF
#!/bin/bash
cd "\$(git rev-parse --show-toplevel)" || exit 1
exec bash "$GATE" "\$@"
EOF
chmod +x scripts/ci/pre-push-validate.sh
git add -A && git commit -qm "fixture" || { echo "setup failed"; exit 1; }

MARKER="$REPO/.git/validation-passed"
gate()  { OUT=$(bash scripts/ci/pre-push-validate.sh 2>&1); ST=$?; }
hook()  { HOUT=$(bash "$HOOK" < /dev/null 2>&1); HST=$?; }
reset() { git checkout -q -- . && git clean -qfd; }

echo "satellite pre-push gate"

# 1. a clean crate passes every tier and writes "<unix time> <HEAD sha>"
gate
check "passes a clean crate" 0 "$ST"
says "runs the architectural tier" "$OUT" "Tier 0: architectural validation"
says "defaults to --all-features, so the feature-gated test runs" "$OUT" "Tests OK: 3 passed"
read -r M_TIME M_SHA < "$MARKER" 2>/dev/null || { M_TIME=""; M_SHA=""; }
[ "$M_SHA" = "$(git rev-parse HEAD)" ] && ok "marker names HEAD" || bad "marker names '$M_SHA', HEAD is $(git rev-parse HEAD)"
NOW=$(date +%s)
[ -n "$M_TIME" ] && [ $((NOW - M_TIME)) -ge 0 ] && [ $((NOW - M_TIME)) -lt 600 ] \
    && ok "marker time is now" || bad "marker time '$M_TIME' is not now ($NOW)"

# 2. hooks/pre-push reads that marker and admits the push
hook
check "pre-push admits the fresh marker" 0 "$HST"
says "pre-push took the marker branch" "$HOUT" "Validation marker OK"

# 3. SATELLITE_FEATURES reaches clippy and the tests
OUT=$(SATELLITE_FEATURES="--no-default-features" bash scripts/ci/pre-push-validate.sh 2>&1); ST=$?
check "passes with the repo's own features" 0 "$ST"
says "the feature-gated test is left out without the feature" "$OUT" "Tests OK: 2 passed"
OUT=$(SATELLITE_FEATURES="--features extra" bash scripts/ci/pre-push-validate.sh 2>&1); ST=$?
says "the feature-gated test runs with --features extra" "$OUT" "Tests OK: 3 passed"

# 4. a commit after validation is not covered by the marker
git commit -q --allow-empty -m "later"
hook
check "pre-push refuses a marker for an earlier commit" 1 "$HST"
says "and says why" "$HOUT" "marker is for a different commit"

# 5. a clippy warning blocks, and removes the marker an earlier run left
gate; [ -f "$MARKER" ] || bad "setup: no marker before the clippy case"
printf '\n/// Returns one.\n#[must_use]\npub const fn one() -> u32 {\n    return 1;\n}\n' >> src/lib.rs
gate
check "refuses a clippy warning" 1 "$ST"
says "names the clippy tier" "$OUT" "BLOCKED: clippy failed."
[ -f "$MARKER" ] && bad "a stale marker survived a failed run" || ok "a failed run leaves no marker"
reset

# 6. rustc warnings are denied too, through build.warnings
printf '\n/// Unused binding.\npub fn unused() {\n    let value = 1;\n}\n' >> src/lib.rs
gate
check "refuses a rustc warning" 1 "$ST"
says "through build.warnings" "$OUT" "build.warnings"
reset

# 7. unformatted code blocks
printf '\npub const fn  spaced ( ) -> u32 { 1 }\n' >> src/lib.rs
gate
check "refuses unformatted code" 1 "$ST"
says "names the fmt tier" "$OUT" "BLOCKED: code is not formatted."
reset

# 8. a failing test blocks
sed -i.orig 's/add(2, 3), 5/add(2, 3), 6/' tests/add_test.rs && rm -f tests/add_test.rs.orig
gate
check "refuses a failing test" 1 "$ST"
says "names the test tier" "$OUT" "BLOCKED: tests failed."
[ -f "$MARKER" ] && bad "a failing test left a marker" || ok "no marker after a failing test"
reset

# 9. a workspace with no test at all verified nothing, so it blocks
rm tests/add_test.rs
gate
check "refuses a run where no test ran" 1 "$ST"
says "says nothing was verified" "$OUT" "no test run"
reset

# 10. the architectural tier runs before any build
touch src/lib.rs.bak
gate
check "refuses what validate.sh refuses" 1 "$ST"
says "names the architectural tier" "$OUT" "BLOCKED: architectural validation failed."
reset

# 11. a cargo older than 1.97 would ignore build.warnings, so it is refused
mkdir -p "$TMP/oldcargo"
printf '#!/bin/sh\necho "cargo 1.96.0 (fixture)"\n' > "$TMP/oldcargo/cargo" && chmod +x "$TMP/oldcargo/cargo"
OUT=$(PATH="$TMP/oldcargo:$PATH" bash scripts/ci/pre-push-validate.sh 2>&1); ST=$?
check "refuses cargo 1.96" 1 "$ST"
says "names build.warnings" "$OUT" "predates build.warnings"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
