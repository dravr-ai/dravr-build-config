#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Tests the AI-attribution guards in commit-msg and pre-push by making them fire
# ABOUTME: Real commits, merges and pushes against a throwaway bare remote; no network

set -u

HOOKS=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
check(){ # <desc> <expected-status> <actual-status>
    [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected exit $2, got $3)"
}
says() { # <desc> <text> <fixed-string>
    printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1 — output lacks '$3': $2"
}

# Hermetic git: no global or system config (signing, a global hooksPath) and no
# identity inherited from the environment. Every repo below sets its own.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_EDITOR=true
printf '[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"
mkdir -p "$TMP/nohooks"

# hooked: git as a consumer runs it, with core.hooksPath at the shared hooks.
# unhooked: history made with the hooks bypassed, or before they existed.
hooked()   { git -c core.hooksPath="$HOOKS" "$@"; }
unhooked() { git -c core.hooksPath="$TMP/nohooks" "$@"; }
human()    { git config user.name "Ada Human"; git config user.email ada@example.com; }
head_sha() { git rev-parse HEAD; }
must()     { "$@" >/dev/null 2>&1 || { echo "setup failed: $*"; exit 1; }; }

# ===================================================================
echo "commit-msg: identity"
mkdir -p "$TMP/work" && cd "$TMP/work" && git init -q . && human
echo seed > seed.txt && git add seed.txt && must hooked commit -qm "chore: seed"

echo a > a.txt && git add a.txt
out=$(hooked commit -m "feat: add a" --author="Claude <claude@example.com>" 2>&1); st=$?
check "refuses an author named Claude" 1 "$st"
says "names the author and why" "$out" 'the author of this commit is an AI identity (named "Claude")'
says "tells the user how to set a human identity" "$out" 'git config user.email "you@example.com"'

out=$(GIT_COMMITTER_EMAIL=noreply@anthropic.com hooked commit -m "feat: add a" 2>&1); st=$?
check "refuses a committer at anthropic.com" 1 "$st"
says "names the committer and why" "$out" "the committer of this commit is an AI identity (address at anthropic.com)"

out=$(hooked -c user.name=cLaUdE commit -m "feat: add a" 2>&1); st=$?
check "refuses a configured user named Claude in any case" 1 "$st"

out=$(hooked commit -m "feat: add a" --author="Claude Monet <monet@example.com>" 2>&1); st=$?
check "allows a name that only starts with Claude" 0 "$st"

echo b > b.txt && git add b.txt
out=$(hooked commit -m "feat: add b" 2>&1); st=$?
check "allows a human commit" 0 "$st"
[ "$(git log -1 --format='%s|%an|%cn')" = "feat: add b|Ada Human|Ada Human" ] \
    && ok "the human commit landed with the human identity" || bad "commit not recorded as expected"

# ===================================================================
echo "commit-msg: attribution lines"
echo c > c.txt && git add c.txt
BEFORE=$(head_sha)

out=$(hooked commit -m "feat: add c" -m "Adds c." -m "Claude-Session: session_013W2HVhji9wGuTG6EayvJtD" 2>&1); st=$?
check "refuses a Claude-Session trailer" 1 "$st"
says "names the line that matched" "$out" "line 5: Claude-Session: session_013W2HVhji9wGuTG6EayvJtD"

out=$(hooked commit -m "feat: add c" -m "Context: https://claude.ai/code/session_01ABC" 2>&1); st=$?
check "refuses a claude.ai/code link" 1 "$st"
says "names the link line" "$out" "line 3: Context: https://claude.ai/code/session_01ABC"

out=$(hooked commit -m "feat: add c" -m "Reviewed-by: Bot <noreply@anthropic.com>" 2>&1); st=$?
check "refuses Anthropic's noreply address in a trailer" 1 "$st"

out=$(hooked commit -m "feat: add c" -m "Co-Authored-By: Claude Opus <x@example.com>" 2>&1); st=$?
check "still refuses a Co-Authored-By naming Claude" 1 "$st"

out=$(hooked commit -m "feat: add c" -m "🤖 Generated with a tool" 2>&1); st=$?
check "still refuses a Generated-with footer" 1 "$st"
[ "$(head_sha)" = "$BEFORE" ] && ok "no refused commit was recorded" || bad "a refused commit landed"

# The diff `git commit -v` appends below the scissors line is not the message.
printf 'feat: add c\n\n# ------------------------ >8 ------------------------\n+Claude-Session: x\n' > "$TMP/verbose-msg"
out=$(bash "$HOOKS/commit-msg" "$TMP/verbose-msg" 2>&1); st=$?
check "ignores attribution text below the scissors line" 0 "$st"
git reset -q

# ===================================================================
echo "commit-msg: merge, squash and amend"
git checkout -q -b side && echo s > s.txt && git add s.txt && must hooked commit -qm "feat: side"
git checkout -q main && echo m > m.txt && git add m.txt && must hooked commit -qm "feat: main"
BEFORE=$(head_sha)

out=$(hooked -c user.name=Claude -c user.email=noreply@anthropic.com \
    merge -m "chore: merge side" side 2>&1); st=$?
[ "$st" -ne 0 ] && ok "refuses a merge commit with an AI author" || bad "merge commit with AI author was made"
says "the merge refusal names the identity" "$out" "Claude <noreply@anthropic.com>"
[ "$(head_sha)" = "$BEFORE" ] && ok "no merge commit was recorded" || bad "an AI merge commit landed"
git merge --abort 2>/dev/null; git reset -q --hard "$BEFORE"

hooked merge -q --squash side >/dev/null 2>&1
out=$(hooked -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "feat: squash side" 2>&1); st=$?
check "refuses a squash commit with an AI author" 1 "$st"
git reset -q --hard "$BEFORE"

out=$(hooked merge -m "chore: merge side" side 2>&1); st=$?
check "allows a human merge commit" 0 "$st"
[ "$(git rev-list --count --merges -1 HEAD)" = "1" ] && ok "the human merge commit landed" || bad "no merge commit"

echo d > d.txt && git add d.txt
unhooked commit -qm "feat: add d" --author="Claude <noreply@anthropic.com>"
out=$(hooked commit --amend -m "feat: add d" 2>&1); st=$?
check "refuses an amend that keeps an AI author" 1 "$st"
out=$(hooked commit --amend --reset-author -m "feat: add d" 2>&1); st=$?
check "allows the amend once --reset-author takes the human identity" 0 "$st"

# ===================================================================
echo "pre-push"
git init -q --bare "$TMP/remote.git"
mkdir -p "$TMP/pp" && cd "$TMP/pp" && git init -q . && human
git remote add origin "$TMP/remote.git"
remote_main() { git ls-remote origin refs/heads/main | cut -f1; }

echo seed > seed.txt && git add seed.txt && must hooked commit -qm "chore: seed"
out=$(hooked push -q origin main 2>&1); st=$?
check "allows a first push of human commits" 0 "$st"
says "reports how many commits it checked" "$out" "1 new commit(s) carry no AI identity or attribution"
PUSHED=$(remote_main)

# An AI-authored commit that bypassed commit-msg.
echo x > x.txt && git add x.txt
unhooked commit -qm "feat: add x" --author="Claude <noreply@anthropic.com>"
AI_SHA=$(head_sha)
out=$(hooked push origin main 2>&1); st=$?
[ "$st" -ne 0 ] && ok "refuses an AI-authored commit the remote lacks" || bad "pushed an AI-authored commit"
says "lists the offending sha as author" "$out" "${AI_SHA:0:12}  author     Claude <noreply@anthropic.com>"
says "prints the one-commit fix" "$out" "git commit --amend --reset-author"
[ "$(remote_main)" = "$PUSHED" ] && ok "the remote did not move" || bad "the remote received the AI commit"

# The printed fix works.
must hooked commit -q --amend --reset-author -m "feat: add x"
out=$(hooked push -q origin main 2>&1); st=$?
check "allows the push once the commit is re-authored" 0 "$st"
PUSHED=$(remote_main)

# An AI committer and a Claude-Session trailer, both made with hooks bypassed,
# with a clean commit between them: both are listed, the base is the older one's parent.
echo y > y.txt && git add y.txt
GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com unhooked commit -qm "feat: add y"
FIRST=$(head_sha)
echo z > z.txt && git add z.txt && must hooked commit -qm "feat: add z"
echo w > w.txt && git add w.txt
unhooked commit -qm "feat: add w" -m "Claude-Session: https://claude.ai/code/session_01"
SECOND=$(head_sha)
out=$(hooked push origin main 2>&1); st=$?
[ "$st" -ne 0 ] && ok "refuses AI committer and trailer commits" || bad "pushed them"
says "lists the AI committer" "$out" "${FIRST:0:12}  committer  Claude <noreply@anthropic.com>"
says "lists the trailer with its line" "$out" "${SECOND:0:12}  message    line 3: Claude-Session: https://claude.ai/code/session_01"
says "rebases from the oldest offender's parent" "$out" "git rebase -i ${FIRST:0:12}^"
[ "$(remote_main)" = "$PUSHED" ] && ok "the remote did not move" || bad "the remote received them"
git reset -q --hard "$PUSHED"

# cherry-pick runs no commit hook and keeps the original author: pre-push is the only net.
git checkout -q -b donor
echo v > v.txt && git add v.txt && unhooked commit -qm "feat: add v" --author="Claude <c@example.com>"
DONOR=$(head_sha)
git checkout -q main && hooked cherry-pick "$DONOR" >/dev/null 2>&1
[ "$(git log -1 --format=%an)" = "Claude" ] || bad "cherry-pick setup did not keep the author"
out=$(hooked push origin main 2>&1); st=$?
[ "$st" -ne 0 ] && ok "refuses a cherry-picked AI-authored commit" || bad "pushed a cherry-picked AI commit"
git reset -q --hard "$PUSHED"; git branch -q -D donor

# History already on the remote never blocks: publish an AI commit with the
# hooks off, as the pre-hook history did, then push human work on top of it.
echo u > u.txt && git add u.txt
unhooked commit -qm "feat: add u" -m "Claude-Session: https://claude.ai/code/session_02" --author="Claude <noreply@anthropic.com>"
must unhooked push -q origin main
echo t > t.txt && git add t.txt && must hooked commit -qm "feat: add t"
out=$(hooked push origin main 2>&1); st=$?
check "allows a push whose only AI commits are already on the remote" 0 "$st"
[ "$(remote_main)" = "$(head_sha)" ] && ok "the remote received the human commit" || bad "remote did not move"

git checkout -q -b feature
echo q > q.txt && git add q.txt && must hooked commit -qm "feat: add q"
out=$(hooked push -q origin feature 2>&1); st=$?
check "allows a new branch whose AI ancestors are on the remote" 0 "$st"

out=$(hooked push -q origin --delete feature 2>&1); st=$?
check "allows a branch deletion" 0 "$st"
[ -z "$(git ls-remote origin refs/heads/feature)" ] && ok "the branch is gone" || bad "branch still present"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
