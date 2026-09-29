#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: The worktree facts the worktree skills share — which root, which path, which repo, which gate
# ABOUTME: Sourced, never executed; every function echoes one value, and only claim_worktree writes
#
# Shared by create-worktree, finish-worktree and merge-and-cleanup in every dravr-*
# repo, so nothing here names a repository: each fact is read from the repo the
# caller stands in. This directory holds no SKILL.md, so ci/bootstrap-repo.sh does
# not link it into .claude/skills; the scripts reach it through their own resolved
# location (.build/skills/<skill>/../lib), whichever path they were invoked by.
#
# `git rev-parse --show-toplevel` means opposite things in the scripts that call
# it: in create/finish-worktree it is the FEATURE worktree the caller is standing
# in, and in merge-and-cleanup it is expected to be MAIN. Reading the same
# expression as two different facts is how a cleanup run from the wrong directory
# removes the wrong tree, so the two are named apart here and no script spells the
# expression again.

# The worktree the caller is standing in.
current_worktree_root() {
    git rev-parse --show-toplevel
}

# The repository's main worktree — always the first entry `git worktree list`
# reports, whichever tree the caller is standing in.
main_worktree_root() {
    git worktree list --porcelain | sed -n 's/^worktree //p' | head -1
}

# ------------------------------------------------------------ per-repo settings
# .claude/worktree.conf, committed in the repo that needs it, holds `key = value`
# lines; `#` starts a comment and surrounding quotes are dropped. It is read from
# the main worktree, the tree every feature worktree's path is computed against,
# and it is never sourced: a value is data, not code. A missing file or key means
# the default.
#
#   prefix   first half of a feature worktree's directory name (default: the main
#            worktree's directory name). dravr-platform sets pierre_mcp_server:
#            its worktrees predate the rename and carry that name on every machine.
worktree_conf() { # $1 = key
    local file
    file="$(main_worktree_root)/.claude/worktree.conf"
    [ -f "$file" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$file" | tail -1 |
        sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# The directory-name prefix of every feature worktree. A prefix naming anything
# but one plain directory component would put worktrees outside the parent
# directory, so it is refused rather than followed.
worktree_prefix() {
    local prefix
    prefix="$(worktree_conf prefix)"
    [ -n "$prefix" ] || prefix="$(basename "$(main_worktree_root)")"
    case "$prefix" in
        . | .. | *[!A-Za-z0-9._-]*)
            echo "Error: worktree prefix '$prefix' (from .claude/worktree.conf) is not a plain directory name." >&2
            return 1
            ;;
    esac
    printf '%s\n' "$prefix"
}

# Where create-worktree.sh puts a feature worktree, and therefore where
# merge-and-cleanup.sh looks for it when the caller names only a branch:
# <parent of the main worktree>/<prefix>-<branch with / as ->.
feature_worktree_path() {
    local branch="$1" prefix
    prefix="$(worktree_prefix)" || return 1
    printf '%s\n' "$(dirname "$(main_worktree_root)")/${prefix}-${branch//\//-}"
}

# The hand-off file finish-worktree.sh writes and merge-and-cleanup.sh reads.
# It lives in the main worktree because that is where the cleanup runs.
last_branch_file() {
    printf '%s\n' "$(main_worktree_root)/.claude/skills/.last-feature-branch"
}

# ------------------------------------------------------------ repo identity
# owner/name on GitHub, for CI links and `gh --repo`. Read from origin's
# configured URL (not `git remote get-url`, which applies insteadOf rewrites),
# which covers https, ssh and scp-style remotes and ssh host aliases such as
# github-work; anything else asks gh. Empty when neither knows, and callers then
# print no link rather than a guessed one.
repo_slug() {
    local url slug name owner
    url="$(git config --get remote.origin.url 2>/dev/null || true)"
    case "$url" in
        *github*/*)
            slug="${url%/}"
            slug="${slug%.git}"
            name="${slug##*/}"
            owner="${slug%/*}"
            owner="${owner##*[/:]}"
            if [ -n "$owner" ] && [ -n "$name" ]; then
                printf '%s/%s\n' "$owner" "$name"
                return 0
            fi
            ;;
    esac
    command -v gh >/dev/null 2>&1 || return 0
    GH_PROMPT_DISABLED=1 gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
}

# The Actions page for one branch, or nothing when the repo slug is unknown.
actions_url() { # $1 = branch
    local slug
    slug="$(repo_slug)"
    [ -n "$slug" ] || return 0
    printf 'https://github.com/%s/actions?query=branch%%3A%s\n' "$slug" "$1"
}

# ------------------------------------------------------------ the pre-push gate
# .build/hooks/pre-push looks for exactly this path: when a repo carries it (the
# platform's own gate, or a satellite's wrapper around
# validation/satellite-pre-push-validate.sh), the hook runs no gate of its own and
# admits a push only on the marker the gate writes. Without it the hook runs its
# inline fallback (validate.sh, fmt, clippy on the changed crates) during the push.
PRE_PUSH_GATE=scripts/ci/pre-push-validate.sh

# The gate's absolute path in the current worktree, or nothing when the repo has none.
pre_push_gate() {
    local gate
    gate="$(current_worktree_root)/$PRE_PUSH_GATE"
    [ -f "$gate" ] && printf '%s\n' "$gate"
    return 0
}

# True when a push from here runs .build/hooks/pre-push. `--git-path hooks`
# honours core.hooksPath, relative to the current directory. A repo with no gate
# script relies on that hook alone, and an unarmed hook reads exactly like a
# passing one.
pre_push_hook_armed() {
    [ -x "$(git rev-parse --git-path hooks)/pre-push" ]
}

# ------------------------------------------------------------ ownership stamp
# Which Claude Code session a worktree belongs to. Nothing in git records it,
# and the status line can only describe the directory a session sits in — so a
# session driving lanes in three worktrees reads as "on main", and the operator
# cannot tell whose tree is whose. The stamp lives in the worktree's own git-dir
# (`.git/worktrees/<name>/claude-session`): outside the working tree, so it never
# dirties it, and removed with the worktree by `git worktree remove`. Written by
# create-worktree.sh and by any lane that adopts a slot; read by the status line
# and by dravr-platform's bin/worktrees.sh. The key=value format is that contract.

worktree_stamp_file() { # $1 = worktree path (default: the caller's)
    local dir="${1:-.}"
    local gitdir
    gitdir="$(git -C "$dir" rev-parse --git-dir 2>/dev/null)" || return 1
    case "$gitdir" in /*) ;; *) gitdir="$(cd "$dir" && cd "$gitdir" && pwd)" ;; esac
    echo "$gitdir/claude-session"
}

# The session's display name: what /rename set, else the id prefix, else the
# shell user when called outside Claude Code. Same resolution carnet.sh uses.
worktree_session_name() {
    local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local sid="${CLAUDE_CODE_SESSION_ID:-}" pid="${CLAUDE_PID:-}" n=""
    if [ -n "$sid" ] && [ -n "$pid" ] && [ -f "$cfg/sessions/$pid.json" ]; then
        n=$(jq -r --arg sid "$sid" 'select(.sessionId == $sid) | .name // empty' \
            "$cfg/sessions/$pid.json" 2>/dev/null || true)
    fi
    [ -n "$n" ] || n="${sid:0:8}"
    [ -n "$n" ] || n="${USER:-shell}"
    printf '%s' "$n"
}

# Stamp a worktree as this session's. Idempotent; re-stamping moves ownership.
claim_worktree() { # $1 = worktree path (default: the caller's)
    local f
    f="$(worktree_stamp_file "${1:-.}")" || return 1
    {
        printf 'session_id=%s\n' "${CLAUDE_CODE_SESSION_ID:-shell}"
        printf 'name=%s\n' "$(worktree_session_name)"
        printf 'pid=%s\n' "${CLAUDE_PID:-$$}"
        printf 'host=%s\n' "$(hostname -s 2>/dev/null || hostname)"
        printf 'claimed_at=%s\n' "$(date +%s)"
    } > "$f"
}

# One field of a worktree's stamp: session_id, name, pid, host or claimed_at.
# Empty when the worktree carries no stamp.
worktree_owner() { # $1 = worktree path, $2 = field (default: name)
    local f field="${2:-name}"
    f="$(worktree_stamp_file "$1")" || return 0
    [ -f "$f" ] || return 0
    sed -n "s/^${field}=//p" "$f" | head -1
}
