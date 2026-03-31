#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Verifies repo's [lints] section is a superset of the baseline
# ABOUTME: Run in CI to prevent lint config drift

set -e

BUILD_DIR="${1:-.build}"
BASELINE="$BUILD_DIR/cargo/lints.toml"
CARGO_TOML="Cargo.toml"

if [ ! -f "$BASELINE" ]; then
    echo "❌ Baseline lint config not found: $BASELINE"
    exit 1
fi

echo "Checking lint configuration against baseline..."

# Extract deny-level lints from baseline
BASELINE_DENIES=$(grep '= "deny"' "$BASELINE" | sed 's/ = .*//' | sed 's/^[[:space:]]*//' | sort)

# Extract deny-level lints from repo
REPO_DENIES=$(grep '= "deny"' "$CARGO_TOML" | sed 's/ = .*//' | sed 's/^[[:space:]]*//' | sort)

# Check that all baseline denies are present in repo
MISSING=$(comm -23 <(echo "$BASELINE_DENIES") <(echo "$REPO_DENIES"))
if [ -n "$MISSING" ]; then
    echo "❌ Repo is missing baseline deny-level lints:"
    echo "$MISSING"
    echo ""
    echo "Add these to your Cargo.toml [lints.clippy] or [workspace.lints.clippy]"
    exit 1
fi

echo "✅ Lint configuration is a superset of baseline"
