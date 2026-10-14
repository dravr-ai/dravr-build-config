#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Tests savoir.sh, and the bootstrap and create-worktree paths that call it, against local repos
# ABOUTME: Opt-in, clone, fast-forward, local edits, a failed clone, the attached-sibling fallback and its origin, the lock; no network

set -u

CI=$(cd "$(dirname "$0")" && pwd)
REPO_SRC=$(cd "$CI/.." && pwd)
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
OUT=""; ST=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
show() { printf '%s\n' "$OUT" | tail -12 | sed 's/^/      | /'; }
says() { # <desc> <fixed-string> — against $OUT
    if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — output lacks '$2'"; show; fi
}
lacks() { # <desc> <fixed-string> — against $OUT
    if printf '%s' "$OUT" | grep -qF -- "$2"; then bad "$1 — output has '$2'"; show; else ok "$1"; fi
}
holds() { # <desc> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
fails() { # <desc> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}
must() {
    local out
    out=$("$@" 2>&1) || { echo "setup failed: $*"; printf '%s\n' "$out" | tail -20; exit 1; }
}
run() { # <dir> <command...> — sets OUT and ST
    local dir="$1"; shift
    OUT=$(cd "$dir" && "$@" 2>&1 < /dev/null); ST=$?
}

unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset CLAUDE_PID CLAUDE_CONFIG_DIR SAVOIR_LOCK_WAIT
export CLAUDE_CODE_SESSION_ID=test-session-0001
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_EDITOR=true GIT_TERMINAL_PROMPT=0
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[user]
	name = Ada Human
	email = ada@example.com
[protocol "file"]
	allow = always
[advice]
	detachedHead = false
EOF
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/direnv"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/direnv" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# The private repo: one consumer's rules and one skill.
SAV="$TMP/savoir-origin"
mkdir -p "$SAV/widget/skills/hello"
printf 'PRIVATE-RULES-LOADED: dravr-savoir/widget\n- rule one\n' > "$SAV/widget/AGENTS.md"
printf -- '---\nname: hello\ndescription: says hello\n---\nhello\n' > "$SAV/widget/skills/hello/SKILL.md"
# The private repo lists the shared .build skills itself, as links that resolve from
# .savoir/<repo>/skills/ back to the consumer's .build/.
ln -s ../../../.build/skills/create-worktree "$SAV/widget/skills/create-worktree"
must git -C "$SAV" init -q
must git -C "$SAV" add -A
must git -C "$SAV" commit -qm "rules v1"
export SAVOIR_URL="$SAV"

# A build-config with this checkout's ci/ and skills/, and a consumer of it.
BUILD="$TMP/build-config"
mkdir -p "$BUILD"
cp -R "$REPO_SRC/skills" "$REPO_SRC/hooks" "$REPO_SRC/ci" "$BUILD/"
must git -C "$BUILD" init -q
must git -C "$BUILD" add -A
must git -C "$BUILD" commit -qm "build v1"
WS="$TMP/ws"
APP="$WS/widget"
mkdir -p "$APP"
must git -C "$APP" init -q
echo hello > "$APP/app.txt"
must git -C "$APP" add -A
must git -C "$APP" commit -qm "chore: seed"
must git -C "$APP" submodule add -q "$BUILD" .build
must git -C "$APP" commit -qm "chore: add .build"
SAVOIR="$APP/.build/ci/savoir.sh"

echo "savoir.sh"

# ---- a repo that has not opted in is left alone, silently
run "$APP" bash "$SAVOIR" sync
[ -z "$OUT" ] && ok "no output when .gitignore does not list .savoir/" || { bad "no output when not opted in"; show; }
fails "no clone when not opted in" test -e "$APP/.savoir"

# ---- opted in: the first sync clones
printf '.savoir/\n' > "$APP/.gitignore"
run "$APP" bash "$SAVOIR" sync
says "the first sync clones" "private agent knowledge cloned: .savoir @"
holds "the rules are in the clone" test -f "$APP/.savoir/widget/AGENTS.md"
holds "the lock is released" test ! -e "$(git -C "$APP" rev-parse --absolute-git-dir)/savoir.lock"

# ---- a new upstream commit is fast-forwarded
printf -- '- rule two\n' >> "$SAV/widget/AGENTS.md"
must git -C "$SAV" commit -qam "rules v2"
run "$APP" bash "$SAVOIR" sync
says "a later sync reports the version" "✅ private agent knowledge: .savoir @ $(git -C "$SAV" log -1 --format=%h)"
holds "and fast-forwards to it" grep -q "rule two" "$APP/.savoir/widget/AGENTS.md"

# ---- local edits are never clobbered
printf -- '- my edit\n' >> "$APP/.savoir/widget/AGENTS.md"
printf -- '- rule three\n' >> "$SAV/widget/AGENTS.md"
must git -C "$SAV" commit -qam "rules v3"
run "$APP" bash "$SAVOIR" sync
says "local edits stop the refresh" "has local edits — not refreshed"
holds "the edit survives" grep -q "my edit" "$APP/.savoir/widget/AGENTS.md"
run "$APP" bash "$SAVOIR" status
says "status names the edits" "with local edits"
must git -C "$APP/.savoir" checkout -q -- .

# ---- a failed refresh keeps the clone and says which version is in use
run "$APP" env SAVOIR_URL="$TMP/nowhere" bash "$SAVOIR" sync
says "an existing clone pulls from its own origin" "✅ private agent knowledge"
must git -C "$APP/.savoir" remote set-url origin "$TMP/nowhere"
run "$APP" bash "$SAVOIR" sync
says "an unreachable origin is reported, the clone kept" "not refreshed"
holds "the clone is still there" test -f "$APP/.savoir/widget/AGENTS.md"

# ---- no clone possible: loud, exit 0, nothing left behind
rm -rf "$APP/.savoir"
run "$APP" env SAVOIR_URL="$TMP/nowhere" bash "$SAVOIR" sync
says "a failed clone is announced" "AGENT KNOWLEDGE ABSENT — clone failed"
[ "$ST" = 0 ] && ok "and still exits 0" || bad "a failed clone exited $ST"
fails "no partial clone is left" test -e "$APP/.savoir"

# ---- the attached sibling of a cloud session is the fallback
must git clone -q "$SAV" "$WS/dravr-savoir"
# A personal checkout beside the repo may sit on a feature branch: the clone takes main.
must git -C "$WS/dravr-savoir" checkout -q -b feature/wip
printf -- '- unreviewed rule\n' >> "$WS/dravr-savoir/widget/AGENTS.md"
must git -C "$WS/dravr-savoir" commit -qam "wip"
run "$APP" env SAVOIR_URL="$TMP/nowhere" bash "$SAVOIR" sync
says "a failed clone falls back to ../dravr-savoir" "cloned from the attached ../dravr-savoir"
holds "the rules come from the sibling" test -f "$APP/.savoir/widget/AGENTS.md"
# carnet#952: origin stays the real repository, the sibling is only a fallback remote.
[ "$(git -C "$APP/.savoir" remote get-url origin)" = "$TMP/nowhere" ] && ok "origin is SAVOIR_URL, not the sibling" \
    || bad "origin is $(git -C "$APP/.savoir" remote get-url origin)"
[ "$(git -C "$APP/.savoir" remote get-url sibling)" = "$WS/widget/../dravr-savoir" ] && ok "the sibling is the remote 'sibling'" \
    || bad "remote sibling is '$(git -C "$APP/.savoir" remote get-url sibling 2>&1)'"
[ "$(git -C "$APP/.savoir" symbolic-ref --short HEAD)" = main ] && ok "the clone is on main, not the sibling's branch" \
    || bad "the clone is on $(git -C "$APP/.savoir" symbolic-ref --short HEAD)"
fails "and has none of that branch's work" grep -q "unreviewed rule" "$APP/.savoir/widget/AGENTS.md"
[ "$(git -C "$APP/.savoir" config branch.main.remote)" = origin ] && ok "main pushes to origin" \
    || bad "main's remote is '$(git -C "$APP/.savoir" config branch.main.remote)'"
run "$APP" env SAVOIR_URL="$TMP/nowhere" bash "$SAVOIR" status
says "status names an origin that is not dravr-savoir on GitHub" "origin $TMP/nowhere"
# origin unreachable: the next sync fast-forwards main from the sibling, and says so.
must git -C "$WS/dravr-savoir" checkout -q main
printf -- '- rule four\n' >> "$WS/dravr-savoir/widget/AGENTS.md"
must git -C "$WS/dravr-savoir" commit -qam "rules v4"
must git -C "$WS/dravr-savoir" checkout -q feature/wip
run "$APP" env SAVOIR_URL="$TMP/nowhere" bash "$SAVOIR" sync
says "an unreachable origin falls back to the sibling's main, named" "fast-forwarded from the attached ../dravr-savoir (sibling/main)"
holds "and brings its main" grep -q "rule four" "$APP/.savoir/widget/AGENTS.md"
fails "never its branch" grep -q "unreviewed rule" "$APP/.savoir/widget/AGENTS.md"
# A commit made in .savoir/ goes to origin, which refuses it here, never into the sibling.
printf -- '- my rule\n' >> "$APP/.savoir/widget/AGENTS.md"
must git -C "$APP/.savoir" commit -qam "my rule"
fails "a push from .savoir/ does not land in the sibling" git -C "$APP/.savoir" push -q
[ -z "$(git -C "$WS/dravr-savoir" log --all --format=%s --grep='my rule')" ] && ok "the sibling's history is untouched" \
    || bad "the commit reached the sibling"
rm -rf "$WS/dravr-savoir" "$APP/.savoir"

# ---- something else at .savoir is not overwritten
rm -rf "$APP/.savoir"; mkdir "$APP/.savoir"; echo mine > "$APP/.savoir/notes"
run "$APP" bash "$SAVOIR" sync
says "a non-clone at .savoir is refused" "exists but is not a git clone"
holds "and left as it was" grep -q mine "$APP/.savoir/notes"
rm -rf "$APP/.savoir"

# ---- the lock: a live one makes the sync stand aside, a stale one is taken over
LOCK="$(git -C "$APP" rev-parse --absolute-git-dir)/savoir.lock"
mkdir "$LOCK"
run "$APP" env SAVOIR_LOCK_WAIT=1 bash "$SAVOIR" sync
says "a held lock defers to the other session" "being synced by another session"
fails "and clones nothing" test -e "$APP/.savoir"
touch -t 202001010000 "$LOCK"
run "$APP" env SAVOIR_LOCK_WAIT=1 bash "$SAVOIR" sync
says "a stale lock is taken over" "private agent knowledge cloned"

echo "bootstrap-repo.sh"

# ---- the skills directory delegated to .savoir resolves after the bootstrap syncs
mkdir -p "$APP/.claude"
ln -s ../.savoir/widget/skills "$APP/.claude/skills"
rm -rf "$APP/.savoir"
run "$APP" bash .build/ci/bootstrap-repo.sh
says "the bootstrap clones .savoir" "private agent knowledge cloned"
holds "so .claude/skills resolves" test -f "$APP/.claude/skills/hello/SKILL.md"
lacks "and nothing is reported dangling" "resolves to nothing"
holds "a shared skill listed by .savoir resolves to .build" test -f "$APP/.claude/skills/create-worktree/create-worktree.sh"
[ -z "$(git -C "$APP/.savoir" status --porcelain)" ] && ok "the bootstrap leaves the clone clean" || { bad "the bootstrap dirtied .savoir"; git -C "$APP/.savoir" status --porcelain | sed 's/^/      | /'; }
lacks "and links nothing into it" "linked shared skill"
run "$APP" bash .build/ci/bootstrap-repo.sh
says "a later bootstrap names the version" "✅ private agent knowledge: .savoir @"

# ---- with no clone possible the bootstrap says so, and creates nothing in its place
rm -rf "$APP/.savoir"
run "$APP" env SAVOIR_URL="$TMP/nowhere" bash .build/ci/bootstrap-repo.sh
says "the bootstrap relays the absence" "AGENT KNOWLEDGE ABSENT"
says "and names the dangling skills link" ".claude/skills -> ../.savoir/widget/skills resolves to nothing"
[ "$ST" = 0 ] && ok "and exits 0" || bad "bootstrap exited $ST"
holds ".claude/skills is still the link, not a directory" test -L "$APP/.claude/skills"

echo "create-worktree.sh"

# ---- a new worktree has the clone before its first session
must git -C "$APP" add -A
must git -C "$APP" commit -qm "chore: delegate skills to .savoir"
run "$APP" bash .build/skills/create-worktree/create-worktree.sh feature/alpha "$WS/widget-alpha"
says "create-worktree syncs .savoir" "private agent knowledge cloned"
holds "the new worktree has the rules" test -f "$WS/widget-alpha/.savoir/widget/AGENTS.md"
holds "and its skills link resolves" test -f "$WS/widget-alpha/.claude/skills/hello/SKILL.md"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
