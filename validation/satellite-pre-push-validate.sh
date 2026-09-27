#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: The pre-push gate every dravr-* satellite runs through its scripts/ci/pre-push-validate.sh
# ABOUTME: Architectural validation, fmt, clippy and the workspace tests, then the marker hooks/pre-push reads
#
# A satellite's scripts/ci/pre-push-validate.sh is a thin wrapper: it cds to its
# repo root, sets SATELLITE_FEATURES and execs this script. hooks/pre-push sees that
# wrapper, stops running its inline clippy gate, and admits a push only when the
# marker this script writes names HEAD and is under 15 minutes old.
#
# Input (environment):
#   SATELLITE_FEATURES  cargo feature arguments for clippy and the tests, split on
#                       spaces (e.g. "--features all-channels"). Default: --all-features.
#   PROJECT_ROOT        the repository to validate. Default: the toplevel of the
#                       current directory's git repository.
#
# Output: $(git rev-parse --absolute-git-dir)/validation-passed holding
# "<unix time> <HEAD sha>", written only when every tier passed. Any earlier
# marker is removed first, so a failed run never leaves one behind.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$PROJECT_ROOT"
export PROJECT_ROOT

MARKER_FILE="$(git rev-parse --absolute-git-dir)/validation-passed"
rm -f "$MARKER_FILE"

fail() {
    echo ""
    echo "BLOCKED: $1"
    exit 1
}

read -r -a FEATURE_ARGS <<< "${SATELLITE_FEATURES:---all-features}"
[ "${#FEATURE_ARGS[@]}" -gt 0 ] || fail "SATELLITE_FEATURES holds only whitespace; unset it for --all-features."

echo "Pre-push validation: $PROJECT_ROOT (features: ${FEATURE_ARGS[*]})"
echo ""

# Clippy and the tests deny warnings through Cargo's build.warnings, which cargo
# before 1.97 ignores without a word, passing every warning. A Homebrew cargo
# ahead of rustup on PATH is the usual way to get one; refuse it.
CARGO_VERSION=$(cargo --version | awk '{print $2}')
CARGO_MAJOR=${CARGO_VERSION%%.*}
CARGO_MINOR=${CARGO_VERSION#*.}
CARGO_MINOR=${CARGO_MINOR%%.*}
if [ "$CARGO_MAJOR" -lt 1 ] || { [ "$CARGO_MAJOR" -eq 1 ] && [ "$CARGO_MINOR" -lt 97 ]; }; then
    fail "cargo $CARGO_VERSION predates build.warnings (cargo 1.97) and would ignore it.
  Put rustup's cargo first on PATH so rust-toolchain.toml selects the pinned toolchain."
fi
export CARGO_BUILD_WARNINGS=deny

# hooks/pre-push runs validate.sh only for repos without this gate, so this tier
# is the only place it runs locally for a satellite. stdin is closed because an
# rg handed an empty path list reads stdin and blocks.
echo "--- Tier 0: architectural validation ---"
if ! bash "$SCRIPT_DIR/validate.sh" < /dev/null; then
    fail "architectural validation failed."
fi
echo ""

echo "--- Tier 1: cargo fmt --all -- --check ---"
if ! cargo fmt --all -- --check; then
    fail "code is not formatted. Run: cargo fmt --all"
fi
echo "Format OK"
echo ""

echo "--- Tier 2: cargo clippy --workspace --all-targets ${FEATURE_ARGS[*]} ---"
if ! cargo clippy --workspace --all-targets "${FEATURE_ARGS[@]}" --quiet; then
    fail "clippy failed."
fi
echo "Clippy OK"
echo ""

echo "--- Tier 3: cargo test --workspace ${FEATURE_ARGS[*]} ---"
TEST_LOG=$(mktemp)
trap 'rm -f "$TEST_LOG"' EXIT
# pipefail makes the pipeline's status cargo's own, so a crashed or failed run
# is judged by its exit status and never by what the log happens to contain.
if ! cargo test --workspace "${FEATURE_ARGS[@]}" 2>&1 | tee "$TEST_LOG"; then
    fail "tests failed."
fi
# cargo exits 0 when no test ran at all, so a gate reading only the status passes
# a workspace whose tests were never built. Count them from the summary lines.
PASSED=$(awk '/^test result: /{ for (i = 1; i <= NF; i++) if ($i ~ /^passed;?$/) sum += $(i - 1) } END { print sum + 0 }' "$TEST_LOG")
if [ "$PASSED" -eq 0 ]; then
    fail "cargo test passed with no test run, so nothing was verified."
fi
echo "Tests OK: $PASSED passed"
echo ""

echo "$(date +%s) $(git rev-parse HEAD)" > "$MARKER_FILE"
echo "All validation passed. Marker: $MARKER_FILE (commit $(git rev-parse --short=12 HEAD), valid 15 minutes)"
