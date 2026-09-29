#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Creates a feature branch in its own git worktree, with .build checked out and the hooks armed
# ABOUTME: Copies the untracked .envrc and .mcp.json when the main worktree has them, and stamps the owner

set -euo pipefail

# Resolve this file through every symlink: a consumer invokes it as
# .claude/skills/create-worktree/create-worktree.sh (a link into .build/skills) or
# straight from .build/skills, and the lib sits beside the real skill directory,
# never beside the link.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
    LINK_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
    SELF="$(readlink "$SELF")"
    case "$SELF" in /*) ;; *) SELF="$LINK_DIR/$SELF" ;; esac
done
SKILLS_DIR="$(cd -P "$(dirname "$SELF")/.." && pwd)"
# shellcheck source=skills/lib/worktree.sh
source "$SKILLS_DIR/lib/worktree.sh"

usage() {
    cat <<'USAGE'
Usage: create-worktree.sh <branch-name> [worktree-path]

Creates <branch-name> from the current HEAD in a new worktree, checks out the
.build submodule there so the git hooks run, copies .envrc and .mcp.json from
the main worktree when it has them, and stamps the worktree as this session's.

  worktree-path  default: <parent of the main worktree>/<prefix>-<branch, / as ->
                 where <prefix> is the main worktree's directory name, or the
                 `prefix` key of a committed .claude/worktree.conf.

Examples:
  create-worktree.sh feature/new-api
  create-worktree.sh fix/bug-123 /tmp/bug-fix
USAGE
    exit 1
}

[[ $# -ge 1 ]] || usage
case "$1" in -h | --help) usage ;; esac

BRANCH_NAME="$1"
MAIN_WORKTREE="$(main_worktree_root)"
if [[ $# -ge 2 ]]; then
    WORKTREE_PATH="$2"
else
    WORKTREE_PATH="$(feature_worktree_path "$BRANCH_NAME")"
fi

echo "Creating worktree for branch: $BRANCH_NAME"
echo "Worktree path: $WORKTREE_PATH"

git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH"

# Populate submodules. NOT optional: core.hooksPath is the relative path
# .build/hooks, which git resolves against each worktree's own root. A fresh
# worktree gets an empty .build/, so git finds no hooks directory and silently
# runs NO hooks at all — commit-msg, pre-commit, and pre-push alike. That reads
# exactly like hooks passing, so an unvalidated push looks clean. The nested
# vendor/llm-registre submodule carries limitation-gates.sh, which validate.sh
# fails without.
echo "Initializing submodules (hooks + validation)..."
git -C "$WORKTREE_PATH" submodule update --init --recursive

if [[ ! -x "$WORKTREE_PATH/.build/hooks/commit-msg" ]]; then
    echo "ERROR: .build/hooks/commit-msg missing after submodule init." >&2
    echo "       This worktree would run with NO git hooks. Fix before committing." >&2
    exit 1
fi

# Stamp the worktree as this session's, so the status line (and, in
# dravr-platform, bin/worktrees.sh) can say whose tree it is. The stamp sits in
# the worktree's git-dir, never in the working tree.
claim_worktree "$WORKTREE_PATH"

# Untracked per-machine files a worktree does not inherit. Not every repo has
# them, and a missing one is not an error.
COPIED_ENVRC=0
for env_file in .envrc .mcp.json; do
    if [[ -f "$MAIN_WORKTREE/$env_file" ]]; then
        cp "$MAIN_WORKTREE/$env_file" "$WORKTREE_PATH/$env_file"
        echo "Copied $env_file from the main worktree."
        [[ "$env_file" == .envrc ]] && COPIED_ENVRC=1
    fi
done

if [[ "$COPIED_ENVRC" -eq 1 ]] && command -v direnv >/dev/null 2>&1; then
    echo "Running direnv allow..."
    (cd "$WORKTREE_PATH" && direnv allow)
fi

echo ""
echo "Worktree created."
echo ""
echo "Next steps:"
echo "  cd $WORKTREE_PATH"
echo ""
