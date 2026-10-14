#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Keeps a repo's git-ignored .savoir/ clone of the private dravr-savoir repo current
# ABOUTME: Opt-in per repo (its .gitignore lists .savoir/); says loudly when the private knowledge is absent
#
# The agent knowledge of the public dravr-* repos — their rules, skills and subagent
# definitions — lives in the private dravr-ai/dravr-savoir. Claude Code reads a CLAUDE.md
# `@` import only from inside the working directory: an import through ../, or through a
# symlink that leads out, is "external" and is dropped without a word unless someone
# approved external imports for that exact project path, which nobody can do headless, in a
# new worktree or in a cloud session. So each checkout carries a real clone at .savoir/,
# ignored by git; its CLAUDE.md imports .savoir/<repo>/AGENTS.md and its .claude/skills,
# .claude/agents and .claude/rules are symlinks into .savoir/<repo>/.
#
# Imports are read before SessionStart hooks run, so a clone made at session start serves
# the NEXT session. The public floor's PRIVATE-RULES-LOADED self-check covers the first
# one, and create-worktree.sh runs `sync` so a new worktree has the clone before then.
#
#   savoir.sh sync     clone .savoir/ when missing, fast-forward it otherwise
#   savoir.sh status   say where .savoir/ stands, touching nothing
#
# SAVOIR_LOCK_WAIT (default 30) is how many seconds a sync waits on another session's.
# SAVOIR_URL overrides the clone source (default https://github.com/dravr-ai/dravr-savoir.git).
# When that clone fails and a sibling ../dravr-savoir exists — a cloud session with the
# repository attached — the clone is made from the sibling's main instead, and then pointed
# back at SAVOIR_URL (carnet#952): `origin` stays the real repository, so a push from
# .savoir/ goes to dravr-savoir or fails loudly, never into the sibling, and bilan's
# unpushed count measures against it. The sibling is kept as a remote named `sibling`, the
# fallback a later sync fast-forwards from — main only, never a branch it happens to be on —
# when origin cannot be reached, and says so.
#
# It never exits non-zero: a session-start hook that fails tells the developer nothing, so
# problems are printed. A repo that has not opted in gets no output at all.

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=8 -o BatchMode=yes}"

URL="${SAVOIR_URL:-https://github.com/dravr-ai/dravr-savoir.git}"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
DEST="$REPO_ROOT/.savoir"

grep -qxE '/?\.savoir/?' "$REPO_ROOT/.gitignore" 2>/dev/null || exit 0

absent() {
    echo "⚠️  AGENT KNOWLEDGE ABSENT — $1"
    echo "   This repo's private rules, skills and subagents are missing from this session."
    echo "   Local: git clone git@github.com:dravr-ai/dravr-savoir.git .savoir"
    echo "   Cloud: attach dravr-ai/dravr-savoir to the session, then: bash .build/ci/savoir.sh sync"
}

head_of() { git -C "$DEST" log -1 --format='%h %cs' 2>/dev/null; }

# ", origin <url>" when .savoir/ does not point at the dravr-savoir repository on GitHub.
origin_note() {
    local origin
    origin=$(git -C "$DEST" remote get-url origin 2>/dev/null) || origin="(none)"
    case "$origin" in
        *github.com[:/]dravr-ai/dravr-savoir | *github.com[:/]dravr-ai/dravr-savoir.git) ;;
        *) printf ', origin %s' "$origin" ;;
    esac
}

# Several sessions start in one checkout at once; two clones into one directory corrupt
# each other. The lock lives in this worktree's git-dir, so each worktree has its own.
LOCK="$(git rev-parse --absolute-git-dir 2>/dev/null)/savoir.lock"
take_lock() {
    local waited=0
    until mkdir "$LOCK" 2>/dev/null; do
        # A lock older than two minutes belongs to a sync that died.
        if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
            rm -rf "$LOCK"
            continue
        fi
        [ "$waited" -ge "${SAVOIR_LOCK_WAIT:-30}" ] && return 1
        sleep 1
        waited=$((waited + 1))
    done
    trap 'rm -rf "$LOCK"' EXIT
}

cmd_status() {
    if [ ! -d "$DEST/.git" ]; then
        absent ".savoir/ is not cloned."
    elif [ -n "$(git -C "$DEST" status --porcelain 2>/dev/null)" ]; then
        echo "✏️  private agent knowledge: .savoir @ $(head_of)$(origin_note), with local edits"
    else
        echo "✅ private agent knowledge: .savoir @ $(head_of)$(origin_note)"
    fi
}

cmd_sync() {
    if ! take_lock; then
        echo "⚠️  .savoir/ is being synced by another session; left as it is."
        cmd_status
        return 0
    fi
    if [ ! -d "$DEST/.git" ]; then
        if [ -e "$DEST" ]; then
            absent ".savoir exists but is not a git clone — move it aside and rerun."
            return 0
        fi
        local err sibling="$REPO_ROOT/../dravr-savoir"
        if err=$(git clone --quiet "$URL" "$DEST" 2>&1); then
            echo "✅ private agent knowledge cloned: .savoir @ $(head_of)"
        elif [ -d "$sibling/.git" ] && git clone --quiet --branch main "$sibling" "$DEST" 2>/dev/null; then
            # main tracks origin/main by configuration even before origin has been
            # fetched once, so `git push` from .savoir/ targets dravr-savoir.
            if git -C "$DEST" remote rename origin sibling 2>/dev/null &&
               git -C "$DEST" remote add origin "$URL" 2>/dev/null &&
               git -C "$DEST" config branch.main.remote origin &&
               git -C "$DEST" config branch.main.merge refs/heads/main; then
                echo "✅ private agent knowledge cloned from the attached ../dravr-savoir (main): .savoir @ $(head_of)"
                echo "   origin is $URL; ../dravr-savoir stays as the remote 'sibling', the fallback when origin cannot be reached"
            else
                rm -rf "$DEST"
                absent "cloned from ../dravr-savoir but could not point origin back at $URL"
            fi
        else
            rm -rf "$DEST"
            absent "clone failed: $(printf '%s' "$err" | tail -1)"
        fi
        return 0
    fi
    # Someone editing the private knowledge in place commits and pushes from .savoir/;
    # a fast-forward never touches that work, and anything else is reported, not forced.
    if [ -n "$(git -C "$DEST" status --porcelain 2>/dev/null)" ]; then
        echo "✏️  .savoir @ $(head_of) has local edits — not refreshed."
        return 0
    fi
    local err branch
    branch=$(git -C "$DEST" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    if err=$(git -C "$DEST" pull --ff-only --quiet 2>&1); then
        echo "✅ private agent knowledge: .savoir @ $(head_of)$(origin_note)"
    elif [ "$branch" = main ] && git -C "$DEST" remote get-url sibling >/dev/null 2>&1 &&
         git -C "$DEST" fetch --quiet sibling main 2>/dev/null &&
         git -C "$DEST" merge --ff-only --quiet sibling/main 2>/dev/null; then
        echo "⚠️  origin could not be reached ($(printf '%s' "$err" | tail -1)); .savoir fast-forwarded from the attached ../dravr-savoir (sibling/main) @ $(head_of)"
    else
        echo "⚠️  .savoir not refreshed ($(printf '%s' "$err" | tail -1)); using .savoir @ $(head_of)$(origin_note)."
    fi
}

case "${1:-}" in
    sync) cmd_sync ;;
    status) cmd_status ;;
    *) echo "usage: savoir.sh sync|status" >&2 ;;
esac
exit 0
