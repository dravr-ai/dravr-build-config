#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Install or update dravr-build-config in a dravr-* repo
# ABOUTME: Sets up submodule, hooks, and symlinks

set -e

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BUILD_DIR="$REPO_ROOT/.build"

if [ -d "$BUILD_DIR" ]; then
    echo "📦 Updating dravr-build-config..."
    git submodule update --remote .build
else
    echo "📦 Installing dravr-build-config..."
    git submodule add https://github.com/dravr-ai/dravr-build-config .build
fi

# Set up git hooks
git config core.hooksPath .build/hooks
echo "✅ Git hooks configured → .build/hooks"

# Symlink configs
for cfg in clippy.toml rustfmt.toml; do
    if [ ! -L "$REPO_ROOT/$cfg" ]; then
        ln -sf .build/cargo/$cfg "$REPO_ROOT/$cfg"
        echo "✅ Symlinked $cfg → .build/cargo/$cfg"
    fi
done

# Check Cargo.toml lints
if [ -f "$REPO_ROOT/Cargo.toml" ]; then
    echo ""
    echo "📋 Run: .build/ci/lint-check.sh"
    echo "   to verify your [lints] match the baseline."
fi

echo ""
echo "✅ dravr-build-config installed at .build/"
echo "   Run: .build/validation/validate.sh to validate your project"
