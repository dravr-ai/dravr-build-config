#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Prepares a feature branch for landing: rebases onto origin/main, runs the repo's pre-push gate, pushes
# ABOUTME: Records the branch and worktree for merge-and-cleanup.sh and prints how to watch this repo's CI

# The whole script is one compound command, so bash has parsed all of it before
# the first line runs. It lives in .build (or in the tree being rebased), and the
# rebase below can rewrite this very file; bash reads a script as it executes it
# and would otherwise carry on at the same byte offset of the new text.
{
set -euo pipefail

# Resolve this file through every symlink: a consumer invokes it as
# .claude/skills/finish-worktree/finish-worktree.sh (a link into .build/skills) or
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

cd "$(current_worktree_root)"

BRANCH_NAME="$(git branch --show-current)"
# Named in the NEXT STEPS text below; under `set -u` an unset name aborts the
# script after the push, which is exactly where it used to die (2026-09-21).
MAIN_WORKTREE="$(main_worktree_root)"
MAIN_BRANCH="main"

if [[ -z "$BRANCH_NAME" ]]; then
    echo "Error: detached HEAD. Check out the feature branch first."
    exit 1
fi

if [[ "$BRANCH_NAME" == "$MAIN_BRANCH" ]]; then
    echo "Error: already on $MAIN_BRANCH. Switch to the feature branch first."
    exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "Error: uncommitted changes on $BRANCH_NAME. Commit them first; a rebase must not carry loose edits."
    git status --short --untracked-files=no
    exit 1
fi

# A repo without its own gate is validated by the pre-push hook alone. When that
# hook is not armed either, the push below would publish unvalidated work that
# looks exactly like validated work, so refuse before touching anything.
if [[ -z "$(pre_push_gate)" ]] && ! pre_push_hook_armed; then
    echo "Error: this repo has no $PRE_PUSH_GATE and no armed pre-push hook"
    echo "       ($(git rev-parse --git-path hooks)/pre-push), so the push would run no gate at all."
    echo "       Arm the hooks with: bash .build/ci/bootstrap-repo.sh"
    exit 1
fi

echo "Finishing branch: $BRANCH_NAME"
echo ""

echo "Fetching origin/$MAIN_BRANCH..."
git fetch origin "$MAIN_BRANCH"

if [[ "$(git rev-parse "origin/$MAIN_BRANCH")" != "$(git merge-base HEAD "origin/$MAIN_BRANCH")" ]]; then
    echo "Rebasing onto origin/$MAIN_BRANCH..."
    if ! git rebase "origin/$MAIN_BRANCH"; then
        echo ""
        echo "Error: the rebase stopped on a conflict. Resolve it, 'git rebase --continue', then rerun."
        exit 1
    fi
    echo "Rebase complete."
    # A rebase onto a main that bumped .build moves the gitlink but not the
    # checkout, so the gate below would run the previous build-config against the
    # new tree. The tree was clean before the rebase, so nothing local is lost.
    git submodule update --init --recursive
else
    echo "Branch is already up to date with $MAIN_BRANCH."
fi

echo ""
# Recomputed after the rebase, which may have brought the gate in or taken it out.
GATE="$(pre_push_gate)"
if [[ -n "$GATE" ]]; then
    # The only local gate: it writes the per-commit marker the pre-push hook
    # checks. Anything heavier runs in CI.
    echo "Running the pre-push gate ($PRE_PUSH_GATE)..."
    if ! bash "$GATE"; then
        echo ""
        echo "Error: the pre-push gate failed. Nothing was pushed. Fix the cause, commit, then rerun."
        exit 1
    fi
else
    echo "No $PRE_PUSH_GATE in this repo: the push below runs .build/hooks/pre-push's"
    echo "inline gate (validate.sh, then fmt and clippy on the changed crates)."
fi

echo ""
echo "Pushing $BRANCH_NAME to origin..."
git push --force-with-lease origin "$BRANCH_NAME"

# Save the branch and worktree for merge-and-cleanup.sh, in the main worktree.
HANDOFF="$(last_branch_file)"
mkdir -p "$(dirname "$HANDOFF")"
echo "$BRANCH_NAME|$(current_worktree_root)" > "$HANDOFF"

SLUG="$(repo_slug)"
if [[ -n "$SLUG" ]]; then
    RUN_LIST="gh run list --repo $SLUG --branch $BRANCH_NAME"
    RUNS_PAGE="$(actions_url "$BRANCH_NAME")"
else
    RUN_LIST="gh run list --branch $BRANCH_NAME"
    RUNS_PAGE="(origin is not a GitHub remote; open its CI page for $BRANCH_NAME)"
fi

cat <<STEPS

Branch pushed.

==========================================
NEXT STEPS
==========================================

1. Watch CI for the branch until every lane is terminal (re-check on a
   schedule; never 'gh run watch', no loop under 60s):
     $RUN_LIST
     $RUNS_PAGE

   A lane that did not run is not a verdict: some repos run a reduced suite
   for some ref names (dravr-platform runs only a smoke on fix/*).

2. Once every lane is green, land it from the main worktree:
     cd $MAIN_WORKTREE
     ./.claude/skills/finish-worktree/merge-and-cleanup.sh -m "<subject>

<body>"

   (Branch and worktree are saved - no other arguments needed.)
STEPS
exit 0
}
