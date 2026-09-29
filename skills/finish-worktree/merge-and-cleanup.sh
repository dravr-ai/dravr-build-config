#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Squash-merges a CI-green feature branch onto main, pushes, then cleans up the branch and worktree
# ABOUTME: Refuses to touch anything it cannot land safely; cleanup runs only once the work is on origin/main

# The whole script is one compound command, so bash has parsed all of it before
# the first line runs. It lives in .build, and the squash below can move .build —
# `git submodule update` then rewrites this very file mid-run; bash reads a
# script as it executes it and would otherwise carry on at the same byte offset
# of the new text.
{
set -euo pipefail

# Resolve this file through every symlink: a consumer invokes it as
# .claude/skills/finish-worktree/merge-and-cleanup.sh (a link into .build/skills)
# or straight from .build/skills, and the lib sits beside the real skill
# directory, never beside the link.
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
Usage: merge-and-cleanup.sh [-m <message> | -F <file>] [branch-name] [worktree-path]

Squash-merges origin/<branch-name> onto main, runs the repo's pre-push gate,
pushes main, and only then removes the worktree and deletes the branch. Run it
from the main worktree, on main, after CI is green on the branch.

  -m <message>   Commit message (subject line, blank line, body). Pass a
                 multi-line string; the commit-msg hook enforces the shape.
  -F <file>      Read the commit message from <file>.

With neither, an interactive terminal opens the editor with the branch's
commit subjects prefilled; a non-interactive run fails instead of guessing.

Without arguments the branch and worktree come from the file written by
finish-worktree.sh. The worktree path defaults to the create-worktree layout
(.claude/worktree.conf's prefix, else the main worktree's directory name).

The gate is scripts/ci/pre-push-validate.sh when the repo has one; otherwise
the push itself runs .build/hooks/pre-push's inline gate.

What it refuses, and why:
  - not on main, or not in the main worktree: the squash must advance the one
    shared main ref.
  - no gate script and no armed pre-push hook: the push would be unvalidated.
  - uncommitted changes that overlap the branch's files: someone's work in
    progress would be swallowed by the squash.
  - anything staged in the main worktree: the squash commit takes the whole
    index, so a peer's staged work would be published under this message.
  - a worktree path that is not where git has the branch checked out (two
    branch names can share one directory name), or a worktree holding
    changes no commit has: removing it would destroy someone's work.
  - local main that cannot fast-forward to origin/main, or that carries
    commits origin/main lacks: unpushed work or a divergence must be
    reconciled by a person, not merged around or published with the squash.
  - origin/main moving while the gate ran, or a rejected push: the squash
    commit stays on local main; the fix is printed, and nothing is cleaned up.

A rerun once the branch's work is on origin/main (after landing a squash by
hand with the printed commands) finds nothing to merge and only cleans up.
Exit 3 means the work is on origin/main and the cleanup stopped; the reason
and the rerun are printed.
USAGE
    exit 1
}

MESSAGE=""
MESSAGE_FILE=""
while getopts ":m:F:h" opt; do
    case "$opt" in
        m) MESSAGE="$OPTARG" ;;
        F) MESSAGE_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

MAIN_WORKTREE="$(main_worktree_root)"
LAST_BRANCH_FILE="$(last_branch_file)"

if [[ "$(current_worktree_root)" != "$MAIN_WORKTREE" ]]; then
    echo "Error: run this from the main worktree ($MAIN_WORKTREE), not from $(current_worktree_root)"
    exit 1
fi
cd "$MAIN_WORKTREE"

# The exact command a stopped run tells the user to rerun: a branch named on the
# command line must be named again, or the rerun would act on whatever the
# hand-off file names.
RERUN="./.claude/skills/finish-worktree/merge-and-cleanup.sh"
if [[ $# -ge 1 ]]; then
    BRANCH_NAME="$1"
    RERUN="$RERUN $(printf '%q' "$1")"
    if [[ $# -ge 2 ]]; then
        WORKTREE_PATH="$2"
        RERUN="$RERUN $(printf '%q' "$2")"
    else
        WORKTREE_PATH="$(feature_worktree_path "$BRANCH_NAME")"
    fi
elif [[ -f "$LAST_BRANCH_FILE" ]]; then
    SAVED_INFO="$(cat "$LAST_BRANCH_FILE")"
    BRANCH_NAME="${SAVED_INFO%%|*}"
    WORKTREE_PATH="${SAVED_INFO##*|}"
    echo "Using saved branch: $BRANCH_NAME"
    echo "Worktree: $WORKTREE_PATH"
    echo ""
else
    echo "Error: no branch specified and no saved branch found."
    echo "Run finish-worktree.sh first, or name the branch."
    echo ""
    usage
fi

if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "Error: must be on main. Currently on: $(git branch --show-current)"
    exit 1
fi

if [[ -z "$(pre_push_gate)" ]] && ! pre_push_hook_armed; then
    echo "Error: this repo has no $PRE_PUSH_GATE and no armed pre-push hook"
    echo "       ($(git rev-parse --git-path hooks)/pre-push), so pushing main would run no gate at all."
    echo "       Arm the hooks with: bash .build/ci/bootstrap-repo.sh"
    exit 1
fi

# How to rerun the gate by hand, for the recovery instructions below; empty when
# the push itself runs the hook's inline gate.
if [[ -n "$(pre_push_gate)" ]]; then
    GATE_HINT="bash $PRE_PUSH_GATE"
else
    GATE_HINT=""
fi

# ---------------------------------------------------------------- the worktree
physical_path() { # $1 = path; itself when it does not exist
    (cd -P "$1" 2>/dev/null && pwd) || printf '%s\n' "$1"
}

# The worktree git has BRANCH_NAME checked out in, resolved; nothing when none.
branch_worktree() {
    local tree
    tree="$(git worktree list --porcelain | awk -v ref="refs/heads/$BRANCH_NAME" '
        /^worktree / { tree = substr($0, 10) }
        $1 == "branch" && $2 == ref { print tree; exit }')"
    [[ -n "$tree" ]] || return 0
    physical_path "$tree"
}

# Why the cleanup must not remove WORKTREE_PATH, one line per fact; nothing
# when it may. `git worktree remove --force` (which the .build submodule
# requires) deletes whatever the tree holds, so the tree must be the one git
# has this branch checked out in — two branch names can share one directory
# name (feature/a-b and feature-a/b) — and hold nothing a commit lacks. The
# untracked .envrc and .mcp.json are create-worktree's own copies.
cleanup_blocker() {
    local holder tree loose
    holder="$(branch_worktree)"
    if [[ ! -d "$WORKTREE_PATH" ]]; then
        # A tree deleted by hand is still registered; `worktree prune` clears it.
        if [[ -n "$holder" ]] && [[ -d "$holder" ]]; then
            echo "$BRANCH_NAME is checked out at $holder, not at $WORKTREE_PATH;"
            echo "name that worktree as the second argument once it is spent."
        fi
        return 0
    fi
    tree="$(physical_path "$WORKTREE_PATH")"
    if [[ "$holder" != "$tree" ]]; then
        if [[ -n "$holder" ]]; then
            echo "$WORKTREE_PATH is not $BRANCH_NAME's worktree (git has the branch at $holder),"
        else
            echo "$WORKTREE_PATH is not $BRANCH_NAME's worktree (no worktree has the branch checked out),"
        fi
        echo "so it may hold another branch's work. Name the right path, or remove that tree by hand."
        return 0
    fi
    loose="$(git -C "$tree" status --porcelain --ignore-submodules=untracked |
        grep -v -x -e '?? .envrc' -e '?? .mcp.json' || true)"
    if [[ -n "$loose" ]]; then
        echo "the worktree at $WORKTREE_PATH holds changes no commit has:"
        printf '%s\n' "$loose" | sed 's/^/   /'
        echo "Commit them on another branch, stash them, or discard them."
    fi
}

BLOCKER="$(cleanup_blocker)"
if [[ -n "$BLOCKER" ]]; then
    echo "Error: the cleanup this run ends with could not remove the worktree:"
    printf '%s\n' "$BLOCKER" | sed 's/^/   /'
    echo "Nothing was touched."
    exit 1
fi

echo "Fetching origin/main and origin/$BRANCH_NAME..."
git fetch origin main "$BRANCH_NAME"
REMOTE_BRANCH="origin/$BRANCH_NAME"

# CI validated what is on origin; merge exactly that. A local branch that is
# ahead of it carries commits no lane has seen.
if git rev-parse --verify --quiet "$BRANCH_NAME" >/dev/null; then
    if [[ "$(git rev-parse "$BRANCH_NAME")" != "$(git rev-parse "$REMOTE_BRANCH")" ]]; then
        echo "Error: local $BRANCH_NAME ($(git rev-parse --short "$BRANCH_NAME")) differs from"
        echo "       $REMOTE_BRANCH ($(git rev-parse --short "$REMOTE_BRANCH")). Push the branch and let CI run first."
        exit 1
    fi
fi

# The main worktree is shared. Unstaged work that does not touch the branch's
# files survives a squash untouched; work that does would be swallowed, so
# refuse rather than guess.
BRANCH_FILES="$(git diff --name-only "origin/main...$REMOTE_BRANCH")"
DIRTY_FILES="$(git status --porcelain --untracked-files=no | cut -c4- | sed 's/.* -> //')"
OVERLAP="$(comm -12 <(printf '%s\n' "$BRANCH_FILES" | sort -u) <(printf '%s\n' "$DIRTY_FILES" | sort -u) | sed '/^$/d')"
if [[ -n "$OVERLAP" ]]; then
    echo "Error: uncommitted changes in the main worktree overlap the branch:"
    printf '   %s\n' "$OVERLAP"
    echo "Commit or stash that work (it is not yours to discard), then rerun."
    exit 1
fi

# The squash commit takes the whole index. A fast-forward squash — the usual
# one, since finish-worktree rebases — keeps whatever else was staged, so a
# peer's half-done `git add` would reach origin/main under this branch's
# message. Nothing may be staged before the squash.
STAGED="$(git diff --cached --name-only)"
if [[ -n "$STAGED" ]]; then
    echo "Error: the main worktree has staged changes, which the squash commit would publish:"
    printf '%s\n' "$STAGED" | sed 's/^/   /'
    echo "They are not this branch's: commit them, or unstage them (git restore --staged <path>), then rerun."
    exit 1
fi

echo "Fast-forwarding local main to origin/main..."
if ! git pull --ff-only origin main; then
    echo ""
    echo "Error: local main cannot fast-forward to origin/main."
    echo "It has unpushed commits or has diverged; reconcile it first"
    echo "(git log --oneline origin/main..main shows what only exists locally)."
    exit 1
fi

# A fast-forward pull succeeds when local main is simply AHEAD, and pushing the
# squash would then publish those commits too. Everything below also relies on
# local main being exactly origin/main.
AHEAD="$(git rev-list --count origin/main..HEAD)"
if [[ "$AHEAD" -gt 0 ]]; then
    echo ""
    echo "Error: local main carries $AHEAD commit(s) origin/main does not have:"
    git log --oneline origin/main..HEAD | sed 's/^/   /'
    echo "Push them (an earlier run's squash lands with the commands that run printed)"
    echo "or drop them, then rerun. A person decides which."
    exit 1
fi

# ---------------------------------------------------------------- cleanup
# Called only once the branch's work is on origin/main. The remote branch goes
# last, because it is a push too: the pre-push hook admits it on the marker the
# gate wrote for the squash commit (or runs its inline gate).
cleanup_landed() { # $1 = what landed, for the closing message
    local landed="$1" blocker
    # Checked before the squash too; the gate can run for minutes, and a
    # session may have written into the tree meanwhile.
    blocker="$(cleanup_blocker)"
    if [[ -n "$blocker" ]]; then
        echo ""
        echo "Error: $landed is on origin/main, but the cleanup stopped before touching anything:"
        printf '%s\n' "$blocker" | sed 's/^/   /'
        echo "Then rerun (it finds nothing to merge and only cleans up):"
        echo "   $RERUN"
        exit 3
    fi
    if [[ -d "$WORKTREE_PATH" ]]; then
        echo ""
        echo "Removing worktree at $WORKTREE_PATH..."
        # A worktree created by create-worktree.sh carries the .build submodule;
        # a plain remove refuses it, so deinit first and force the removal.
        git -C "$WORKTREE_PATH" submodule deinit -f --all >/dev/null 2>&1 || true
        git worktree remove --force "$WORKTREE_PATH"
    else
        echo ""
        echo "Worktree not found at $WORKTREE_PATH (already removed)."
    fi
    git worktree prune

    if git rev-parse --verify --quiet "$BRANCH_NAME" >/dev/null; then
        # A squash is not seen as a merge, so only -D deletes the branch.
        git branch -D "$BRANCH_NAME"
    fi

    echo "Deleting $REMOTE_BRANCH..."
    if ! git push origin --delete "$BRANCH_NAME"; then
        echo ""
        echo "Error: $landed is on origin/main and the worktree and local branch are gone,"
        echo "but deleting $REMOTE_BRANCH was refused (reason above)."
        if [[ -n "$GATE_HINT" ]]; then
            echo "The pre-push hook admits a push on a fresh marker for HEAD: run '$GATE_HINT',"
            echo "then rerun (it finds nothing to merge and only cleans up):"
        else
            echo "Resolve the refusal, then rerun (it finds nothing to merge and only cleans up):"
        fi
        echo "   $RERUN"
        exit 3
    fi

    rm -f "$LAST_BRANCH_FILE"

    local slug main_runs
    slug="$(repo_slug)"
    main_runs="$(actions_url main)"
    echo ""
    echo "$landed is on main; branch and worktree cleaned up."
    echo ""
    echo "AFTER PUSHING - REQUIRED: watch main's CI until every lane is terminal."
    if [[ -n "$slug" ]]; then
        echo "   gh run list --repo $slug --branch main --limit 15"
        echo "   $main_runs"
    else
        echo "   gh run list --branch main --limit 15"
    fi
    echo "Not 'gh run watch' and no loop under 60s; re-check on a schedule."
    echo ""
    exit 0
}

# Undo a squash that was staged and not committed. A merge never moves a
# submodule checkout, so only the superproject's index and tree need restoring;
# with submodule.recurse=true a plain reset would also try to move .build back
# from a pointer whose commit it never fetched, fail, and leave the squash staged.
undo_squash() {
    git -c submodule.recurse=false reset --merge
}

echo "Squash-merging $REMOTE_BRANCH..."
if ! git merge --squash "$REMOTE_BRANCH"; then
    echo ""
    echo "Error: the squash did not apply cleanly. Restoring the index and tree."
    undo_squash
    echo "Rebase the branch onto origin/main in its worktree (finish-worktree.sh), let CI run, then rerun."
    exit 1
fi

# Nothing staged: local main is exactly origin/main (checked above) and already
# holds every change the branch makes — a squash landed by hand after an earlier
# run stopped. The work is on origin, so only the cleanup is left.
if git diff --cached --quiet; then
    rm -f "$(git rev-parse --git-path SQUASH_MSG)"
    echo ""
    echo "origin/main already carries every change on $REMOTE_BRANCH; nothing to merge."
    cleanup_landed "$REMOTE_BRANCH's work"
fi

echo ""
echo "Staged for the squash commit:"
git diff --cached --name-only | sed 's/^/   /'
echo ""

TMP_MESSAGE="$(mktemp)"
trap 'rm -f "$TMP_MESSAGE"' EXIT
if [[ -n "$MESSAGE" ]]; then
    printf '%s\n' "$MESSAGE" > "$TMP_MESSAGE"
elif [[ -n "$MESSAGE_FILE" ]]; then
    cp "$MESSAGE_FILE" "$TMP_MESSAGE"
elif [[ -t 0 ]]; then
    {
        echo ""
        echo ""
        echo "# Squash of $BRANCH_NAME. Line 1: subject (<=72 chars). Line 2: blank."
        echo "# Line 3+: what changed and why. Lines starting with # are dropped."
        echo "# The branch's commits, oldest first:"
        git log --reverse --format='#   %s' "origin/main..$REMOTE_BRANCH"
    } > "$TMP_MESSAGE"
    "${EDITOR:-vi}" "$TMP_MESSAGE"
    sed -i.bak '/^#/d' "$TMP_MESSAGE" && rm -f "$TMP_MESSAGE.bak"
else
    echo "Error: no commit message. Pass -m or -F when running non-interactively."
    undo_squash
    exit 1
fi

if [[ -z "$(sed '/^[[:space:]]*$/d' "$TMP_MESSAGE")" ]]; then
    echo "Error: empty commit message. The squash is undone; rerun with a message."
    undo_squash
    exit 1
fi

# The index held nothing before the squash (refused above), so the commit
# carries exactly the branch's changes; a peer's unstaged edits stay put.
git commit -F "$TMP_MESSAGE"
echo ""

# A squash that moves a submodule pointer (.build) leaves the checkout on the
# old one — a merge never updates submodules — so the gate below would run the
# PREVIOUS build-config against the new tree. That is how a squash that taught
# registre.toml a new key failed its own gate: the vendored gate it needed was
# committed and not checked out. Sync first, so the gate is the one the commit
# records.
git submodule update --init --recursive

# The pre-push hook checks a per-commit marker; the feature worktree's marker
# is for another commit, so the gate runs again here, on the squash. A failure
# leaves the squash on local main with nothing pushed or cleaned up, and says
# so rather than exiting on the gate's last line. Recomputed after the squash,
# which may have brought the gate in.
GATE="$(pre_push_gate)"
if [[ -n "$GATE" ]]; then
    GATE_HINT="bash $PRE_PUSH_GATE"
    echo "Running the pre-push gate on the squash commit ($PRE_PUSH_GATE)..."
    if ! bash "$GATE"; then
        echo ""
        echo "Error: the gate failed on the squash commit $(git rev-parse --short HEAD), which is on local main."
        echo "Nothing was pushed and nothing was cleaned up. Fix the cause, rerun the gate, push, then rerun"
        echo "for the cleanup (it finds nothing to merge and only cleans up):"
        echo "   $RERUN"
        exit 1
    fi
else
    echo "No $PRE_PUSH_GATE in this repo: pushing main runs .build/hooks/pre-push's inline gate."
fi

# Main can move while the gate runs (auto-bumps land on their own). Look
# before pushing so the failure names itself instead of surfacing as a
# rejected push, and never pipe the push: a pipe hides its exit status, and a
# masked rejection followed by cleanup is how a landed-looking squash got its
# worktree deleted out from under it.
git fetch origin main
if [[ "$(git rev-parse HEAD~1)" != "$(git rev-parse origin/main)" ]]; then
    echo ""
    echo "Error: origin/main moved to $(git rev-parse --short origin/main) while the gate ran."
    echo "The squash commit $(git rev-parse --short HEAD) is on local main. To land it:"
    # submodule.recurse=true makes pull refuse to rebase a commit that moves a
    # submodule pointer ("cannot rebase with locally recorded submodule
    # modifications"), and a squash bumping .build is exactly that commit.
    echo "   git -c submodule.recurse=false pull --rebase origin main && git submodule update --init --recursive"
    if [[ -n "$GATE_HINT" ]]; then
        echo "   $GATE_HINT"
    fi
    echo "   git push origin main"
    echo "then rerun for the cleanup (it finds nothing to merge and only cleans up):"
    echo "   $RERUN"
    exit 2
fi

echo "Pushing main..."
if ! git push origin main; then
    echo ""
    echo "Error: the push was rejected. The squash commit $(git rev-parse --short HEAD) is on local main."
    echo "Nothing was cleaned up. Resolve the refusal above; when main moved, reconcile with"
    echo "   git -c submodule.recurse=false pull --rebase origin main && git submodule update --init --recursive"
    if [[ -n "$GATE_HINT" ]]; then
        echo "and rerun '$GATE_HINT'. Then push, and rerun for the cleanup:"
    else
        echo "Then push, and rerun for the cleanup:"
    fi
    echo "   $RERUN"
    exit 2
fi

cleanup_landed "squash $(git rev-parse --short HEAD)"
}
