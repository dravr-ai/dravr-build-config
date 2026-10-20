#!/usr/bin/env bash
# ABOUTME: Fixture test for validate.sh's one-integration-test-binary-per-crate scan ([test_layout] one_binary)
# ABOUTME: Pins the stray-file and env-writing-module failures, the autotests=false exemption, the opt-out count and fail-closed rg
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

# The environment-writing call, spelled so this file holds no literal one.
ENV_CALL="std::env::se""t_var(\"MODE\", \"1\");"

# repo <name> <one_binary: on|off> — a clean repo with one crate, crates/demo; prints its root
repo() {
  local root="$WORK/$1"
  mkdir -p "$root/crates/demo/src"
  printf 'pub fn double(n: u32) -> u32 {\n    n * 2\n}\n' >"$root/crates/demo/src/lib.rs"
  if [ "$2" = on ]; then printf '[test_layout]\none_binary = true\n' >"$root/validation-patterns.local.toml"; fi
  printf '%s\n' "$root"
}
# put <file> <body> — writes a test file, creating its directory
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
# it_binary <crate dir> — tests/it/main.rs with one suite module
it_binary() {
  put "$1/tests/it/main.rs" 'mod double_test;'
  put "$1/tests/it/double_test.rs" '#[test]
fn doubles() {}'
}
# validate_exit <root> — runs $VALIDATE there, output in $WORK/out
validate_exit() {
  local root=$1 code=0
  ( cd "$root" && PROJECT_ROOT="$root" bash "$VALIDATE" >"$WORK/out" 2>&1 </dev/null ) || code=$?
  echo "$code"
}
plain() { sed 's/\x1b\[[0-9;]*m//g' "$WORK/out"; }

echo "one-test-binary fixture tests"

# A compliant crate: one binary, plus a top-level suite that writes the environment.
root="$(repo compliant on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/tests/env_override_test.rs" "#[test]
fn reads_override() {
    unsafe { $ENV_CALL }
}"
if [ "$(validate_exit "$root")" = "0" ] && plain | grep -q '✅ One integration test binary per crate'; then
  pass "tests/it plus an environment-writing top-level suite passes"
else
  fail "a compliant crate did not pass: $(plain | grep -E '❌|binar' || true)"
fi

# A stray top-level suite that writes no environment is a binary of its own.
root="$(repo stray on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/tests/stray_test.rs" '#[test]
fn stray() {}'
if [ "$(validate_exit "$root")" = "1" ] && plain | grep -q 'outside one test binary per crate' && plain | grep -q 'crates/demo/tests/stray_test.rs'; then
  pass "a stray top-level test file fails and names the file"
else
  fail "a stray top-level test file passed: $(plain | grep -E '❌|binar' || true)"
fi

# A doc comment naming the function writes nothing, so it does not exempt a stray file.
root="$(repo mention on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/tests/mention_test.rs" '/// Never calls se''t_var: reads only.
#[test]
fn mention() {}'
if [ "$(validate_exit "$root")" = "1" ] && plain | grep -q 'crates/demo/tests/mention_test.rs'; then
  pass "a file that only mentions the call is still a stray binary"
else
  fail "a mention exempted a stray file: $(plain | grep -E '❌|binar' || true)"
fi

# A module of the shared binary that writes the environment, nested one level down.
root="$(repo env-in-it on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/tests/it/nested/env_test.rs" "#[test]
fn writes() {
    unsafe { $ENV_CALL }
}"
if [ "$(validate_exit "$root")" = "1" ] && plain | grep -q 'crates/demo/tests/it/nested/env_test.rs: writes the process environment'; then
  pass "an environment-writing module inside tests/it fails and names the file"
else
  fail "an environment-writing module inside tests/it passed: $(plain | grep -E '❌|binar' || true)"
fi

# autotests = false: the crate declares its binaries, including one under a subdirectory
# behind a feature, so only tests/it is checked.
root="$(repo no-autotests on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/Cargo.toml" '[package]
name = "demo"
autotests = false

[[test]]
name = "it"
path = "tests/it/main.rs"

[[test]]
name = "live"
path = "tests/live/main.rs"
required-features = ["live"]'
put "$root/crates/demo/tests/live/main.rs" '#[test]
fn live() {}'
put "$root/crates/demo/tests/declared_test.rs" '#[test]
fn declared() {}'
if [ "$(validate_exit "$root")" = "0" ] && plain | grep -q '✅ One integration test binary per crate'; then
  pass "an autotests = false crate with [[test]] entries passes"
else
  fail "an autotests = false crate failed: $(plain | grep -E '❌|binar' || true)"
fi

# The root package's tests/ is a crate like any other.
root="$(repo root-stray on)"
put "$root/tests/root_stray_test.rs" '#[test]
fn root() {}'
if [ "$(validate_exit "$root")" = "1" ] && plain | grep -q 'tests/root_stray_test.rs'; then
  pass "a stray file in the root package's tests/ fails"
else
  fail "the root package's tests/ was not scanned: $(plain | grep -E '❌|binar' || true)"
fi

# Cargo also makes a binary of tests/<dir>/main.rs; one that writes no environment is a
# stray like a top-level file.
root="$(repo dir-stray on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/tests/live/main.rs" 'mod checks;'
put "$root/crates/demo/tests/live/checks.rs" '#[test]
fn live() {}'
if [ "$(validate_exit "$root")" = "1" ] && plain | grep -q 'crates/demo/tests/live/main.rs: a test binary of its own'; then
  pass "a tests/<dir>/main.rs binary that writes no environment fails and names the file"
else
  fail "a tests/<dir>/main.rs stray binary passed: $(plain | grep -E '❌|binar' || true)"
fi

# A directory suite whose environment write sits in one of its modules is kept.
root="$(repo dir-env on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/tests/live/main.rs" 'mod checks;'
put "$root/crates/demo/tests/live/checks.rs" "#[test]
fn writes() {
    unsafe { $ENV_CALL }
}"
if [ "$(validate_exit "$root")" = "0" ] && plain | grep -q '✅ One integration test binary per crate'; then
  pass "a tests/<dir>/main.rs suite that writes the environment in a module passes"
else
  fail "an environment-writing directory suite failed: $(plain | grep -E '❌|binar' || true)"
fi

# autotests = false exempts only the top-level files: a tests/it module writing the
# environment still fails.
root="$(repo no-autotests-env on)"
it_binary "$root/crates/demo"
put "$root/crates/demo/Cargo.toml" '[package]
name = "demo"
autotests = false

[[test]]
name = "it"
path = "tests/it/main.rs"'
put "$root/crates/demo/tests/it/env_test.rs" "#[test]
fn writes() {
    unsafe { $ENV_CALL }
}"
if [ "$(validate_exit "$root")" = "1" ] && plain | grep -q 'crates/demo/tests/it/env_test.rs: writes the process environment'; then
  pass "an autotests = false crate still fails on an environment-writing tests/it module"
else
  fail "autotests = false exempted a tests/it environment write: $(plain | grep -E '❌|binar' || true)"
fi

# Off: the same stray layout passes and the scan counts each crate's binaries, a
# tests/<dir>/main.rs among them; a module of a directory suite is not one.
root="$(repo off off)"
it_binary "$root/crates/demo"
put "$root/crates/demo/tests/stray_test.rs" '#[test]
fn stray() {}'
put "$root/crates/demo/tests/live/main.rs" 'mod checks;'
put "$root/crates/demo/tests/live/checks.rs" '#[test]
fn live() {}'
if [ "$(validate_exit "$root")" = "0" ] && plain | grep -q 'Integration test binaries per crate: demo=3 '; then
  pass "with the flag off a stray file passes and the scan counts 3 binaries"
else
  fail "the opt-out count is wrong: $(plain | grep -E '❌|binar' || true)"
fi

# Fail closed: an rg that crashes on the environment-write scan fails the validation and
# reports no pass. The shim crashes that one call and runs the real rg otherwise.
real_rg="$(command -v rg)"
mkdir -p "$WORK/shim"
printf '#!/bin/bash\ncase "$*" in *_var*) echo "rg: simulated crash" >&2; exit 2;; esac\nexec %s "$@"\n' "$real_rg" >"$WORK/shim/rg"
chmod +x "$WORK/shim/rg"
root="$(repo crash on)"
it_binary "$root/crates/demo"
if [ "$(PATH="$WORK/shim:$PATH" validate_exit "$root")" = "1" ] && plain | grep -q 'rg could not run the test environment-write scan' &&
   ! plain | grep -q '✅ One integration test binary per crate'; then
  pass "a crashed rg fails the scan and reports no pass"
else
  fail "a crashed rg read as clean: $(plain | grep -E '❌|binar' || true)"
fi
root="$(repo crash-off off)"
it_binary "$root/crates/demo"
if [ "$(PATH="$WORK/shim:$PATH" validate_exit "$root")" = "1" ] && ! plain | grep -q 'Integration test binaries per crate'; then
  pass "and with the flag off it prints no count"
else
  fail "a crashed rg printed a count with the flag off: $(plain | grep -E '❌|binar' || true)"
fi

if [ "$failures" -gt 0 ]; then
  echo "one-test-binary: $passes passed · $failures failed"
  exit 1
fi
echo "one-test-binary: $passes passed · 0 failed"
