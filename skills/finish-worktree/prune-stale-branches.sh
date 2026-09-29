#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Lists the local branches other sessions left behind and deletes only those whose work is provably on main
# ABOUTME: Read-only by default; --apply deletes the proven-merged ones and never touches a branch checked out in a worktree

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: prune-stale-branches.sh [--apply] [repo-path ...]

Sweeps the local branches of each repo (default: the current one) and says, for
each, whether its work is already on origin/main. Squash merges leave the
feature branch behind, so these pile up across sessions.

A branch counts as merged when ANY of these holds:
  patch-equivalent  every commit has a patch-identical twin on main (git cherry)
  squash            the branch's whole diff matches one commit on main (patch-id)
  content           every file the branch touched is byte-identical on main

Never considered: main, and any branch checked out in a worktree (a session is
using it). Everything else is UNMERGED and printed with its commits and files:
port what is still valid, or ask whoever owns the work. A merge-tree trial
merge is NOT a merged test: it conflicts whenever main changed the same lines
again later, and flags work that landed long ago.

  --apply   delete the branches proven merged (git branch -D: a squash merge is
            not seen as a merge). Remote branches are never touched.
USAGE
    exit 1
}

APPLY=0
REPOS=()
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) REPOS+=("$arg") ;;
    esac
done
[ "${#REPOS[@]}" -eq 0 ] && REPOS=(".")

# Prints the reason the branch is merged, or nothing when it is not.
#
# The verdict deletes branches, so every git call is captured before it is
# tested and a failed one means "not proven": a pipeline into `grep -q` lets git
# die of SIGPIPE once grep has its answer, and under pipefail that failure would
# read as "no unmerged commit"; an empty file list from a failed diff would read
# as "every file matches".
merged_reason() {
    local repo="$1" branch="$2" cherry base diff_id main_ids files file on_branch on_main
    cherry=$(git -C "$repo" cherry origin/main "$branch") || return 0
    if ! grep -q '^+' <<< "$cherry"; then
        echo "patch-equivalent"
        return 0
    fi
    base=$(git -C "$repo" merge-base origin/main "$branch") || return 0
    diff_id=$(git -C "$repo" diff "$base" "$branch" | git patch-id --stable | awk '{print $1}') || diff_id=""
    if [ -n "$diff_id" ]; then
        main_ids=$(git -C "$repo" log -p --format='commit %H' "$base..origin/main" |
            git patch-id --stable | awk '{print $1}') || main_ids=""
        if grep -qxF "$diff_id" <<< "$main_ids"; then
            echo "squash"
            return 0
        fi
    fi
    files=$(git -C "$repo" diff --name-only "$base" "$branch") || return 0
    [ -n "$files" ] || return 0
    while IFS= read -r file; do
        on_branch=$(git -C "$repo" rev-parse -q --verify "$branch:$file" 2>/dev/null || true)
        on_main=$(git -C "$repo" rev-parse -q --verify "origin/main:$file" 2>/dev/null || true)
        [ "$on_branch" = "$on_main" ] || return 0
    done <<< "$files"
    echo "content"
}

for repo in "${REPOS[@]}"; do
    git -C "$repo" fetch -q --prune origin
    echo "=== $(basename "$(git -C "$repo" rev-parse --show-toplevel)")"
    checked_out=$(git -C "$repo" worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}')
    while IFS= read -r branch; do
        [ "$branch" = "main" ] && continue
        if grep -qxF "$branch" <<< "$checked_out"; then
            echo "  in use     $branch (checked out in a worktree)"
            continue
        fi
        reason=$(merged_reason "$repo" "$branch")
        if [ -n "$reason" ]; then
            if [ "$APPLY" -eq 1 ]; then
                git -C "$repo" branch -D "$branch" >/dev/null
                echo "  deleted    $branch (merged: $reason)"
            else
                echo "  merged     $branch ($reason) — safe to delete"
            fi
        elif ! base=$(git -C "$repo" merge-base origin/main "$branch"); then
            echo "  UNMERGED   $branch (shares no history with origin/main)"
        else
            echo "  UNMERGED   $branch (last commit $(git -C "$repo" log -1 --format=%cs "$branch"))"
            git -C "$repo" log --format='             %h %s' "$base..$branch"
            git -C "$repo" diff --name-only "$base" "$branch" | while IFS= read -r file; do
                if git -C "$repo" cat-file -e "origin/main:$file" 2>/dev/null; then
                    echo "             differs from main: $file"
                else
                    echo "             not on main:       $file"
                fi
            done
        fi
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads)
done
