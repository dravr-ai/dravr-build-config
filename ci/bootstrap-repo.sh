#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Self-healing bootstrap every dravr-* repo runs at Claude Code session start
# ABOUTME: Teaches git to auto-sync .build, repairs a stale submodule, links shared skills
#
# Why this exists: git does NOT update a submodule when you pull the superproject
# unless submodule.recurse is set. So a pull that advances the .build gitlink leaves
# .build/ sitting at the old revision, and everything that resolves THROUGH it —
# core.hooksPath, validate.sh, and the .claude/skills symlinks pointing into
# .build/skills — silently degrades. A skill whose symlink target no longer exists
# does not error; it simply disappears from the skill list, which is indistinguishable
# from never having existed. This script closes that gap in two ways: it sets the git
# config that makes future pulls self-heal, and it repairs the current checkout.
#
# It never exits non-zero. A session-start hook that fails tells the developer nothing
# actionable and turns every real problem into hook noise, so problems are reported as
# text and the exit status is always 0.

# A credential or passphrase prompt inside a session-start hook hangs the session with
# no visible cause. Refuse to prompt; a failed fetch is reported and survivable.
export GIT_TERMINAL_PROMPT=0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO_ROOT" || exit 0

FIXED=""
WARNED=""

fixed() { FIXED="${FIXED}   ${1}"$'\n'; }
warned() { WARNED="${WARNED}   ${1}"$'\n'; }

# ============================================================================
# 1. Durable git config — the fix that outlives this script
# ============================================================================
# These three settings are what actually stop the drift. Everything below only
# repairs the damage that accumulated before they were set.
#
#   submodule.recurse      pull/checkout/switch/merge/rebase/reset update .build
#   fetch.recurseSubmodules  a moved gitlink fetches the commit it now points at
#   push.recurseSubmodules   refuse to push a gitlink whose .build commit is not
#                            on the remote — the "I bumped .build but forgot to
#                            push dravr-build-config" mistake, caught at push time.
#
# push.recurseSubmodules is set explicitly because submodule.recurse alone would
# make push behave as "on-demand" and silently push .build for you; "check" is the
# guard without the surprise. Command-specific config wins over submodule.recurse.
ensure_config() {
    local key="$1" want="$2" have
    have=$(git config --local --get "$key" 2>/dev/null)
    [ "$have" = "$want" ] && return 0
    git config --local "$key" "$want" 2>/dev/null && fixed "git config $key=$want"
}

# Is .build a submodule of THIS repo? A gitlink is mode 160000 in the tree.
PINNED=$(git ls-tree HEAD .build 2>/dev/null | awk '$2 == "commit" { print $3 }')

if [ -n "$PINNED" ]; then
    ensure_config core.hooksPath .build/hooks
    ensure_config submodule.recurse true
    ensure_config fetch.recurseSubmodules on-demand
    ensure_config push.recurseSubmodules check
fi

# ============================================================================
# 2. Repair a stale or missing submodule checkout
# ============================================================================
# `git submodule status --recursive` prefixes each line: '-' not initialized,
# '+' checked out at a commit other than the one the superproject records,
# 'U' merge conflict, ' ' in sync. Reading it recursively also covers the nested
# vendor/llm-registre, whose limitation-gates.sh validate.sh needs.
if [ -n "$PINNED" ]; then
    SYNC_ALL=0
    SAFE_PATHS=""

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        flag=$(printf '%s' "$line" | cut -c1)
        path=$(printf '%s' "$line" | awk '{ print $2 }')
        [ -z "$path" ] && continue

        case "$flag" in
            -)
                # Never checked out: there is nothing local to lose. A nested
                # submodule under an uninitialized parent is not even listed yet,
                # so a full recursive update is the only way to reach it.
                SYNC_ALL=1
                ;;
            +)
                # Checked out at the wrong commit. Moving HEAD is only safe when
                # the developer has nothing invested in the current state.
                if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
                    warned "$path has uncommitted changes — NOT touching it (stale vs $PINNED)"
                elif branch=$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null); then
                    warned "$path is on branch '$branch' — NOT touching it; commit and push, then bump the gitlink"
                else
                    SAFE_PATHS="$SAFE_PATHS $path"
                fi
                ;;
            U)
                warned "$path has a merge conflict — resolve it before the hooks can be trusted"
                ;;
        esac
    done <<EOF
$(git submodule status --recursive 2>/dev/null)
EOF

    if [ "$SYNC_ALL" = "1" ]; then
        if git submodule update --init --recursive --quiet 2>/dev/null; then
            fixed "checked out .build (and nested submodules) at the pinned revision"
        else
            warned "could not check out .build — run: git submodule update --init --recursive"
        fi
    elif [ -n "$SAFE_PATHS" ]; then
        # Word-splitting the collected paths is intentional.
        # shellcheck disable=SC2086
        if git submodule update --init --recursive --quiet -- $SAFE_PATHS 2>/dev/null; then
            fixed "synced$SAFE_PATHS to the revision this repo pins"
        else
            warned "could not sync$SAFE_PATHS — run: git submodule update --init --recursive"
        fi
    fi
fi

# ============================================================================
# 3. Hook integrity
# ============================================================================
# core.hooksPath is the RELATIVE path .build/hooks, which git resolves against
# each working tree's own root. A fresh worktree starts with an empty .build/, so
# git finds no hooks directory and runs NO hooks at all — commit-msg, pre-commit
# and pre-push alike. That is indistinguishable from every hook passing, which is
# how an unvalidated push looks clean.
if [ -n "$PINNED" ]; then
    MISSING_HOOKS=""
    for hook in pre-commit commit-msg pre-push; do
        [ -x ".build/hooks/$hook" ] || MISSING_HOOKS="$MISSING_HOOKS $hook"
    done
    [ -n "$MISSING_HOOKS" ] &&
        warned "git hooks MISSING:$MISSING_HOOKS — this checkout commits and pushes UNVALIDATED"
fi

# ============================================================================
# 4. Shared skills: link what .build offers, report what dangles
# ============================================================================
# Skills shipped in .build/skills are shared across every consumer repo, but each
# repo still has to expose them under .claude/skills. Linking is idempotent and
# only ever creates a name that is absent — a real directory of the same name is
# a repo-local skill and always wins.
SKILL_DIR="$REPO_ROOT/.claude/skills"
if [ -d "$REPO_ROOT/.build/skills" ] && [ -d "$SKILL_DIR" ]; then
    for shared in "$REPO_ROOT"/.build/skills/*/; do
        [ -d "$shared" ] || continue
        name=$(basename "$shared")
        target="$SKILL_DIR/$name"
        # -e follows symlinks, -L catches a dangling one: together they mean
        # "nothing occupies this name", which is the only case safe to create.
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            ln -s "../../.build/skills/$name" "$target" 2>/dev/null &&
                fixed "linked shared skill '$name' (commit the symlink to share it)"
        fi
    done
fi

# A symlink whose target vanished is the failure this whole script exists to make
# visible: Claude Code lists no error, the skill is simply gone.
for dir in "$SKILL_DIR" "$REPO_ROOT/.claude/agents"; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*; do
        [ -L "$entry" ] || continue
        [ -e "$entry" ] && continue
        warned "DEAD symlink $(basename "$dir")/$(basename "$entry") -> $(readlink "$entry")"
    done
done

# ============================================================================
# 5. Report
# ============================================================================
if [ -n "$WARNED" ]; then
    printf '⚠️  dravr bootstrap needs attention:\n%s' "$WARNED"
fi
if [ -n "$FIXED" ]; then
    printf '🔧 dravr bootstrap repaired:\n%s' "$FIXED"
fi
if [ -z "$WARNED" ] && [ -z "$FIXED" ]; then
    echo "✅ .build in sync, hooks armed, skills resolve"
fi

exit 0
