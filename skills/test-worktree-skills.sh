#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Tests the shared worktree skills end to end in a throwaway consumer of a throwaway .build
# ABOUTME: Real worktrees, hooks, a .build bump and a bare origin; the repo's gate is a stub; no network

set -u

SKILLS=$(cd "$(dirname "$0")" && pwd)
REPO_SRC=$(cd "$SKILLS/.." && pwd)
# Physical path: worktree lists and --show-toplevel report resolved paths, and
# macOS's mktemp answers through the /var -> /private/var link.
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
OUT=""; ST=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
show() { printf '%s\n' "$OUT" | tail -12 | sed 's/^/      | /'; }
check() { # <desc> <expected-status> — against $ST
    if [ "$ST" = "$2" ]; then ok "$1"; else bad "$1 (expected exit $2, got $ST)"; show; fi
}
says() { # <desc> <fixed-string> — against $OUT
    if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — output lacks '$2'"; show; fi
}
lacks() { # <desc> <fixed-string> — against $OUT
    if printf '%s' "$OUT" | grep -qF -- "$2"; then bad "$1 — output has '$2'"; show; else ok "$1"; fi
}
is() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}
holds() { # <desc> <command...> — passes when the command succeeds
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
fails() { # <desc> <command...> — passes when the command fails
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}
must() { # a setup step: stops the test, with the step's output, when it fails
    local out
    out=$("$@" 2>&1) || { echo "setup failed: $*"; printf '%s\n' "$out" | tail -20; exit 1; }
}
run() { # <dir> <command...> — sets OUT and ST; stdin is never a terminal
    local dir="$1"; shift
    OUT=$(cd "$dir" && "$@" 2>&1 < /dev/null); ST=$?
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }

# Hermetic git: no global or system config, one human identity, local file
# submodules allowed. The session id makes the ownership stamp predictable.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset CLAUDE_PID CLAUDE_CONFIG_DIR
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

# direnv and gh stand-ins: direnv records where it was allowed, and gh answers
# nothing, so no repo identity can come from the network.
export FLAGS="$TMP/flags" ORIGIN_BARE="$TMP/origin.git"
mkdir -p "$FLAGS" "$TMP/bin" "$TMP/nohooks"
cat > "$TMP/bin/direnv" <<'EOF'
#!/bin/sh
echo "$PWD $*" >> "$FLAGS/direnv.log"
EOF
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/direnv" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# ===================================================================
# A build-config holding this checkout's skills, hooks and bootstrap.
BUILD="$TMP/build-config"
mkdir -p "$BUILD"
cp -R "$REPO_SRC/skills" "$REPO_SRC/hooks" "$REPO_SRC/ci" "$BUILD/"
must git -C "$BUILD" init -q
must git -C "$BUILD" add -A
must git -C "$BUILD" commit -qm "build v1"

# A consumer whose origin reads as GitHub but lands in a local bare repo.
must git init -q --bare "$ORIGIN_BARE"
WS="$TMP/ws"
APP="$WS/widget"
mkdir -p "$APP/scripts/ci"
must git -C "$APP" init -q
must git -C "$APP" remote add origin https://github.com/acme/widget.git
must git -C "$APP" config "url.$ORIGIN_BARE.insteadOf" https://github.com/acme/widget.git

# The repo's gate, stubbed: it logs the commit and the .build it validated, can
# fail, move origin/main or write into a worktree on request, and writes the
# marker hooks/pre-push reads.
cat > "$APP/scripts/ci/pre-push-validate.sh" <<'EOF'
#!/bin/bash
# Stand-in for a repo's pre-push gate: logs what it validated, then writes the marker
set -e
cd "$(git rev-parse --show-toplevel)"
if [ -f "$FLAGS/gate-fails" ]; then echo "stub gate: refusing on purpose"; exit 1; fi
echo "$(git rev-parse HEAD) $(git -C .build rev-parse HEAD)" >> "$FLAGS/gate.log"
if [ -f "$FLAGS/write-into" ]; then
    echo "written while the gate ran" > "$(cat "$FLAGS/write-into")"
    rm -f "$FLAGS/write-into"
fi
if [ -f "$FLAGS/move-origin" ]; then
    rm -f "$FLAGS/move-origin"
    side="$FLAGS/side-mover"
    git clone -q "$ORIGIN_BARE" "$side"
    echo moved > "$side/moved.txt"
    git -C "$side" add moved.txt
    git -C "$side" commit -qm "chore: main moves during the gate"
    git -C "$side" push -q origin main
fi
echo "$(date +%s) $(git rev-parse HEAD)" > "$(git rev-parse --absolute-git-dir)/validation-passed"
echo "stub gate: passed"
EOF
chmod +x "$APP/scripts/ci/pre-push-validate.sh"
echo hello > "$APP/app.txt"
printf '.envrc\n' > "$APP/.gitignore"
must git -C "$APP" add -A
must git -C "$APP" commit -qm "chore: seed"
must git -C "$APP" submodule add -q "$BUILD" .build
must git -C "$APP" commit -qm "chore: add .build"

run "$APP" bash .build/ci/bootstrap-repo.sh
BOOT="$OUT"
must git -C "$APP" add .claude
must git -C "$APP" commit -qm "chore: link the shared skills"
must git -C "$APP" push -q origin main

FINISH=./.claude/skills/finish-worktree/finish-worktree.sh
MERGE=./.claude/skills/finish-worktree/merge-and-cleanup.sh
HANDOFF="$APP/.claude/skills/.last-feature-branch"
remote_sha() { git -C "$APP" ls-remote origin "refs/heads/$1" | cut -f1; }
remote_has() { [ -n "$(remote_sha "$1")" ]; }
local_has()  { git -C "$APP" rev-parse -q --verify "refs/heads/$1"; }
advance_origin() { # <file> — lands one commit on origin/main from another clone
    local side="$TMP/side-$1"
    must git clone -q "$ORIGIN_BARE" "$side"
    echo "$1" > "$side/$1"
    must git -C "$side" add "$1"
    must git -C "$side" commit -qm "chore: add $1"
    must git -C "$side" push -q origin main
}

# ===================================================================
echo "bootstrap-repo.sh"
OUT="$BOOT"
says "links finish-worktree" "linked shared skill 'finish-worktree'"
says "links create-worktree" "linked shared skill 'create-worktree'"
lacks "does not link skills/lib, which has no SKILL.md" "'lib'"
is "the link resolves into .build" "../../.build/skills/finish-worktree" "$(readlink "$APP/.claude/skills/finish-worktree")"
fails "no .claude/skills/lib entry" exists "$APP/.claude/skills/lib"

# ===================================================================
echo "create-worktree"
echo 'export WIDGET=1' > "$APP/.envrc"
run "$APP" ./.claude/skills/create-worktree/create-worktree.sh feature/alpha
check "creates a worktree through the .claude/skills link" 0
ALPHA="$WS/widget-feature-alpha"
says "defaults to <repo dir>-<branch, / as ->" "Worktree path: $ALPHA"
is "the branch is checked out there" "feature/alpha" "$(git -C "$ALPHA" branch --show-current 2>/dev/null)"
holds ".build is checked out, so the hooks run there" test -x "$ALPHA/.build/hooks/commit-msg"
holds ".envrc is copied" test -f "$ALPHA/.envrc"
fails "a .mcp.json the main worktree lacks is skipped" exists "$ALPHA/.mcp.json"
is "direnv allow ran in the new worktree" "$ALPHA allow" "$(cat "$FLAGS/direnv.log" 2>/dev/null)"
STAMP="$(git -C "$ALPHA" rev-parse --git-dir)/claude-session"
holds "the worktree is stamped with the session" grep -qx "session_id=test-session-0001" "$STAMP"

mkdir -p "$APP/.claude"
printf '# Feature worktrees are <parent>/<prefix>-<branch>.\nprefix = legacy_name  # the name before the rename\n' \
    > "$APP/.claude/worktree.conf"
must git -C "$APP" add .claude/worktree.conf
must git -C "$APP" commit -qm "chore: keep the legacy worktree prefix"
must git -C "$APP" push -q origin main
rm -f "$APP/.envrc"

run "$APP" ./.build/skills/create-worktree/create-worktree.sh fix/beta
check "creates a worktree when run straight from .build" 0
BETA="$WS/legacy_name-fix-beta"
says "honours the prefix in .claude/worktree.conf" "Worktree path: $BETA"
holds "the worktree is at the override path" test -d "$BETA/.build/hooks"
fails "no .envrc in the main worktree: none copied" exists "$BETA/.envrc"
lacks "and nothing said about it" ".envrc"
is "direnv did not run without an .envrc" "1" "$(wc -l < "$FLAGS/direnv.log" | tr -d ' ')"

printf 'prefix = ../escape\n' > "$APP/.claude/worktree.conf"
run "$APP" ./.claude/skills/create-worktree/create-worktree.sh fix/escape
check "refuses a prefix that is not a plain directory name" 1
says "and names it" "worktree prefix '../escape'"
fails "no branch was created" local_has fix/escape
must git -C "$APP" checkout -q -- .claude/worktree.conf

ln -s "$APP/.claude/skills/create-worktree/create-worktree.sh" "$TMP/bin/new-worktree"
run "$APP" new-worktree --help
says "a symlink to the script itself still finds the lib" "Usage: create-worktree.sh"
lacks "no missing file on the way" "No such file"

run "$APP" ./.claude/skills/create-worktree/create-worktree.sh feature/gamma
GAMMA="$WS/legacy_name-feature-gamma"
check "creates feature/gamma" 0
run "$APP" ./.claude/skills/create-worktree/create-worktree.sh feature/nogate
NOGATE="$WS/legacy_name-feature-nogate"
check "creates feature/nogate" 0

# ===================================================================
# The facts the scripts, the status line and dravr-platform's bin/worktrees.sh
# read. `--show-toplevel` means the FEATURE tree in create/finish-worktree and
# MAIN in merge-and-cleanup; a helper that blurred the two would let a cleanup
# run from a feature tree remove the wrong one, so each is read from both.
echo "lib/worktree.sh"
LIB="$APP/.build/skills/lib/worktree.sh"
lib() { # <dir> <function> [args...] — the lib's answer, standing in <dir>
    local dir="$1"; shift
    # shellcheck source=skills/lib/worktree.sh
    (cd "$dir" && . "$LIB" && "$@") 2>/dev/null
}
is "main_worktree_root from the main worktree" "$APP" "$(lib "$APP" main_worktree_root)"
is "main_worktree_root from a feature worktree still names main" "$APP" "$(lib "$ALPHA" main_worktree_root)"
is "current_worktree_root from the main worktree" "$APP" "$(lib "$APP" current_worktree_root)"
is "current_worktree_root from a feature worktree names that worktree" "$ALPHA" "$(lib "$ALPHA" current_worktree_root)"
is "feature_worktree_path resolves the same from either worktree" \
    "$(lib "$APP" feature_worktree_path feature/x)" "$(lib "$ALPHA" feature_worktree_path feature/x)"
is "last_branch_file lives in the main worktree, wherever it is called from" \
    "$APP/.claude/skills/.last-feature-branch" "$(lib "$ALPHA" last_branch_file)"
is "worktree_owner is empty on an unstamped worktree" "" "$(lib "$APP" worktree_owner "$APP" name)"
is "worktree_owner reads the session id back" "test-session-0001" "$(lib "$APP" worktree_owner "$ALPHA" session_id)"
is "the name falls back to the id prefix when no session file names it" "test-ses" "$(lib "$APP" worktree_owner "$ALPHA" name)"
is "worktree_owner defaults to the name field" "test-ses" "$(lib "$ALPHA" worktree_owner "$ALPHA")"
is "the stamp leaves the working tree clean" "" "$(git -C "$ALPHA" status --porcelain)"
CLAUDE_CODE_SESSION_ID=fedcba9876543210 lib "$ALPHA" claim_worktree
is "re-claiming from inside the worktree moves ownership" "fedcba9876543210" "$(lib "$APP" worktree_owner "$ALPHA" session_id)"
CLAUDE_CODE_SESSION_ID='' lib "$APP" claim_worktree "$APP"
is "outside Claude Code the stamp names the shell user" "${USER:-shell}" "$(lib "$APP" worktree_owner "$APP" name)"
is "outside Claude Code the session id reads as shell" "shell" "$(lib "$APP" worktree_owner "$APP" session_id)"

# ===================================================================
echo "finish-worktree: refusals"
run "$APP" "$FINISH"
check "refuses on main" 1
says "and says so" "already on main"

echo dirt >> "$ALPHA/app.txt"
run "$ALPHA" "$FINISH"
check "refuses uncommitted changes" 1
says "and names the branch" "uncommitted changes on feature/alpha"
fails "nothing was pushed" remote_has feature/alpha
must git -C "$ALPHA" checkout -q -- app.txt

must git -C "$ALPHA" checkout -q --detach
run "$ALPHA" "$FINISH"
check "refuses a detached HEAD" 1
must git -C "$ALPHA" checkout -q feature/alpha

must git -C "$NOGATE" rm -q scripts/ci/pre-push-validate.sh
must git -C "$NOGATE" commit -qm "chore: drop the stub gate"
OUT=$(cd "$NOGATE" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$TMP/nohooks" \
    "$FINISH" 2>&1 < /dev/null); ST=$?
check "refuses when neither a gate script nor an armed hook would validate" 1
says "and says why" "no armed pre-push hook"
fails "nothing was pushed" remote_has feature/nogate

echo "finish-worktree: a repo without a gate script"
run "$NOGATE" "$FINISH"
check "lands on the pre-push hook's inline gate" 0
says "says the hook validates the push" "No scripts/ci/pre-push-validate.sh in this repo"
holds "the branch reached origin" remote_has feature/nogate

# ===================================================================
echo "finish-worktree: rebase, gate, push"
echo v2 >> "$BUILD/skills/finish-worktree/SKILL.md"
must git -C "$BUILD" commit -qam "build v2"
BUILD_V2=$(git -C "$BUILD" rev-parse HEAD)
must git -C "$ALPHA/.build" fetch -q origin
must git -C "$ALPHA/.build" checkout -q "$BUILD_V2"
echo alpha > "$ALPHA/alpha.txt"
echo "hello from alpha" > "$ALPHA/app.txt"
must git -C "$ALPHA" add .build alpha.txt app.txt
must git -C "$ALPHA" commit -qm "feat: alpha, on build v2"
advance_origin side-one.txt

run "$ALPHA" "$FINISH"
check "finishes feature/alpha" 0
says "rebases onto the moved origin/main" "Rebasing onto origin/main"
says "runs the repo's gate" "Running the pre-push gate (scripts/ci/pre-push-validate.sh)"
says "names this repo's runs, read from origin" "gh run list --repo acme/widget --branch feature/alpha"
says "links this repo's Actions page" "https://github.com/acme/widget/actions?query=branch%3Afeature/alpha"
lacks "links no other repository" "github.com/dravr-ai"
is "pushed exactly the rebased HEAD" "$(git -C "$ALPHA" rev-parse HEAD)" "$(remote_sha feature/alpha)"
is "the hand-off in the main worktree names branch and worktree" "feature/alpha|$ALPHA" "$(cat "$HANDOFF" 2>/dev/null)"
ORIGIN_MAIN=$(remote_sha main)

# ===================================================================
echo "merge-and-cleanup: refusals"
must git -C "$ALPHA" commit -q --allow-empty -m "wip: not pushed"
run "$APP" "$MERGE" -m "feat: land alpha"
check "refuses a local branch ahead of what CI saw" 1
says "and says so" "differs from"
must git -C "$ALPHA" reset -q --hard HEAD~1

run "$ALPHA" "$MERGE" -m "feat: land alpha"
check "refuses outside the main worktree" 1
says "and names the main worktree" "run this from the main worktree ($APP)"

must git -C "$APP" checkout -q -b scratch
run "$APP" "$MERGE" -m "feat: land alpha"
check "refuses off main" 1
says "and names the branch" "Currently on: scratch"
must git -C "$APP" checkout -q main
must git -C "$APP" branch -q -D scratch

echo "local edit" >> "$APP/app.txt"
run "$APP" "$MERGE" -m "feat: land alpha"
check "refuses uncommitted work that overlaps the branch" 1
says "and lists the file" "app.txt"
must git -C "$APP" checkout -q -- app.txt

# A fast-forward squash keeps the rest of the index, so this file would ride
# along to origin/main inside the squash commit.
echo "a peer's half-done work" > "$APP/peer.txt"
must git -C "$APP" add peer.txt
run "$APP" "$MERGE" -m "feat: land alpha"
check "refuses anything staged in the main worktree, which the squash would publish" 1
says "and names it" "peer.txt"
is "the peer's work is still staged, and only it" "peer.txt" "$(git -C "$APP" diff --cached --name-only)"
is "origin/main did not move" "$ORIGIN_MAIN" "$(remote_sha main)"
must git -C "$APP" rm -q --cached peer.txt
rm -f "$APP/peer.txt"

echo "a draft" > "$ALPHA/draft.txt"
echo "an edit" >> "$ALPHA/alpha.txt"
run "$APP" "$MERGE" -m "feat: land alpha"
check "refuses when the worktree it would remove holds work no commit has" 1
says "and lists the untracked file" "?? draft.txt"
says "and the edit" " M alpha.txt"
says "and says nothing was touched" "Nothing was touched."
is "origin/main did not move" "$ORIGIN_MAIN" "$(remote_sha main)"
holds "the draft is still there" test -f "$ALPHA/draft.txt"
rm -f "$ALPHA/draft.txt"
must git -C "$ALPHA" checkout -q -- alpha.txt

echo local > "$APP/local.txt"
must git -C "$APP" add local.txt
must git -C "$APP" commit -qm "chore: local only"
run "$APP" "$MERGE" -m "feat: land alpha"
check "refuses a local main that diverged from origin/main" 1
says "and says so" "cannot fast-forward"
must git -C "$APP" reset -q --hard HEAD~1

must git -C "$APP" pull -q --ff-only origin main
echo local > "$APP/local.txt"
must git -C "$APP" add local.txt
must git -C "$APP" commit -qm "chore: local only"
run "$APP" "$MERGE" -m "feat: land alpha"
check "refuses a local main carrying commits origin/main lacks" 1
says "and lists them" "chore: local only"
must git -C "$APP" reset -q --hard HEAD~1

BEFORE=$(git -C "$APP" rev-parse HEAD)
run "$APP" "$MERGE"
check "refuses to invent a commit message" 1
says "and says so" "no commit message"
is "main did not move" "$BEFORE" "$(git -C "$APP" rev-parse HEAD)"
holds "the squash was undone" git -C "$APP" diff --cached --quiet

touch "$FLAGS/gate-fails"
run "$APP" "$MERGE" -m "feat: land alpha"
check "stops when the gate fails on the squash" 1
says "and says where the squash is" "which is on local main"
is "origin/main did not move" "$ORIGIN_MAIN" "$(remote_sha main)"
holds "the worktree is kept" test -d "$ALPHA"
rm -f "$FLAGS/gate-fails"
must git -C "$APP" reset -q --hard origin/main
must git -C "$APP" submodule update -q --init --recursive

# ===================================================================
echo "merge-and-cleanup: main moves while the gate runs"
touch "$FLAGS/move-origin"
MSG=$'feat: land alpha\n\nAlpha arrives with build v2.'
run "$APP" "$MERGE" -m "$MSG"
check "stops with exit 2" 2
says "names the move" "origin/main moved"
says "prints the gate among the recovery steps" "bash scripts/ci/pre-push-validate.sh"
is "the gate validated the squash on the .build the squash records" \
    "$(git -C "$APP" rev-parse HEAD) $BUILD_V2" "$(tail -1 "$FLAGS/gate.log")"
is "the squash carries exactly the message" "$MSG" "$(git -C "$APP" log -1 --format=%B)"
holds "the worktree is kept" test -d "$ALPHA"
holds "the local branch is kept" local_has feature/alpha
holds "the remote branch is kept" remote_has feature/alpha
holds "the hand-off is kept" test -f "$HANDOFF"

# The recovery, exactly as printed.
must bash -c "cd '$APP' && git -c submodule.recurse=false pull -q --rebase origin main && git submodule update -q --init --recursive"
must bash -c "cd '$APP' && bash scripts/ci/pre-push-validate.sh"
must git -C "$APP" push -q origin main
run "$APP" "$MERGE"
check "a rerun after landing by hand only cleans up" 0
says "finds nothing to merge" "nothing to merge"
fails "the worktree is removed" exists "$ALPHA"
fails "the local branch is deleted" local_has feature/alpha
fails "the remote branch is deleted" remote_has feature/alpha
fails "the hand-off is removed" exists "$HANDOFF"
holds "alpha.txt is on origin/main" git -C "$APP" cat-file -e origin/main:alpha.txt
is "origin/main records .build v2" "$BUILD_V2" "$(git -C "$APP" rev-parse origin/main:.build)"

# ===================================================================
echo "merge-and-cleanup: squash, push, cleanup in one run"
echo beta > "$BETA/beta.txt"
must git -C "$BETA" add beta.txt
must git -C "$BETA" commit -qm "feat: beta"
touch "$FLAGS/gate-fails"
run "$BETA" "$FINISH"
check "finish-worktree stops when the gate fails" 1
says "and says nothing was pushed" "Nothing was pushed"
fails "nothing was pushed" remote_has fix/beta
rm -f "$FLAGS/gate-fails"
run "$BETA" "$FINISH"
check "finishes fix/beta" 0
is "the gate after the rebase ran on the .build main now records" \
    "$(git -C "$BETA" rev-parse HEAD) $BUILD_V2" "$(tail -1 "$FLAGS/gate.log")"

ORIGIN_MAIN=$(remote_sha main)
run "$APP" "$MERGE" -m "feat: land beta" fix/beta
check "lands a branch named on the command line" 0
says "reports the landing" "is on main; branch and worktree cleaned up."
says "points at this repo's main runs" "gh run list --repo acme/widget --branch main --limit 15"
says "and its Actions page" "https://github.com/acme/widget/actions?query=branch%3Amain"
lacks "links no other repository" "github.com/dravr-ai"
is "origin/main is the squash" "$(git -C "$APP" rev-parse HEAD)" "$(remote_sha main)"
is "one commit on top of the old origin/main" "$ORIGIN_MAIN" "$(git -C "$APP" rev-parse HEAD~1)"
is "with the human's name" "Ada Human" "$(git -C "$APP" log -1 --format=%an)"
is "and the message given, nothing appended" "feat: land beta" "$(git -C "$APP" log -1 --format=%B)"
fails "the prefix-derived worktree is removed" exists "$BETA"
fails "the local branch is deleted" local_has fix/beta
fails "the remote branch is deleted" remote_has fix/beta
fails "the hand-off is removed" exists "$HANDOFF"

# ===================================================================
echo "merge-and-cleanup: origin rejects the push"
echo gamma > "$GAMMA/gamma.txt"
must git -C "$GAMMA" add gamma.txt
must git -C "$GAMMA" commit -qm "feat: gamma"
run "$GAMMA" "$FINISH"
check "finishes feature/gamma" 0
cat > "$ORIGIN_BARE/hooks/pre-receive" <<EOF
#!/bin/sh
while read -r old new ref; do
    if [ "\$ref" = refs/heads/main ] && [ -f "$FLAGS/reject" ]; then echo "main is locked"; exit 1; fi
    case "\$new" in
        *[!0]*) ;;
        *) if [ -f "$FLAGS/reject-delete" ]; then echo "deletions are locked"; exit 1; fi ;;
    esac
done
exit 0
EOF
chmod +x "$ORIGIN_BARE/hooks/pre-receive"
touch "$FLAGS/reject"
ORIGIN_MAIN=$(remote_sha main)
run "$APP" "$MERGE" -m "feat: land gamma"
check "stops with exit 2" 2
says "says the push was rejected" "the push was rejected"
says "passes origin's reason through" "main is locked"
is "origin/main did not move" "$ORIGIN_MAIN" "$(remote_sha main)"
holds "the worktree is kept" test -d "$GAMMA"
holds "the remote branch is kept" remote_has feature/gamma
rm -f "$FLAGS/reject"
must git -C "$APP" push -q origin main
touch "$FLAGS/reject-delete"
run "$APP" "$MERGE"
check "a rerun after the push stops with exit 3 when origin refuses the deletion" 3
says "finds nothing to merge" "nothing to merge"
says "says what is done and what is not" "deleting origin/feature/gamma was refused"
fails "the worktree is removed" exists "$GAMMA"
fails "the local branch is deleted" local_has feature/gamma
holds "the remote branch is kept" remote_has feature/gamma
holds "the hand-off is kept for the next rerun" test -f "$HANDOFF"
rm -f "$FLAGS/reject-delete"
run "$APP" "$MERGE"
check "the next rerun finishes the cleanup" 0
says "notes the worktree is already gone" "already removed"
fails "the remote branch is deleted" remote_has feature/gamma
fails "the hand-off is removed" exists "$HANDOFF"

# ===================================================================
echo "merge-and-cleanup: the worktree it removes"
run "$APP" ./.claude/skills/create-worktree/create-worktree.sh feature/delta
check "creates feature/delta" 0
DELTA="$WS/legacy_name-feature-delta"
echo delta > "$DELTA/delta.txt"
must git -C "$DELTA" add delta.txt
must git -C "$DELTA" commit -qm "feat: delta"
run "$DELTA" "$FINISH"
check "finishes feature/delta" 0
DELTA_STAMP="$(git -C "$DELTA" rev-parse --absolute-git-dir)/claude-session"
holds "the worktree carries its ownership stamp" test -f "$DELTA_STAMP"
# Checked before the squash, and again before the removal: the gate can run
# for minutes, and a session may write into the tree meanwhile.
printf '%s\n' "$DELTA/late.txt" > "$FLAGS/write-into"
run "$APP" "$MERGE" -m "feat: land delta"
check "stops with exit 3 when the worktree gained work while the gate ran" 3
says "says the work is on origin/main" "is on origin/main, but the cleanup stopped"
says "and names the file" "late.txt"
says "and prints the rerun" "./.claude/skills/finish-worktree/merge-and-cleanup.sh"
is "origin/main is the squash" "$(git -C "$APP" rev-parse HEAD)" "$(remote_sha main)"
holds "the file written meanwhile survives" test -f "$DELTA/late.txt"
holds "the local branch is kept" local_has feature/delta
holds "the remote branch is kept" remote_has feature/delta
holds "the hand-off is kept" test -f "$HANDOFF"
rm -f "$DELTA/late.txt"
run "$APP" "$MERGE"
check "the rerun only cleans up" 0
says "finds nothing to merge" "nothing to merge"
fails "the worktree is removed" exists "$DELTA"
fails "its ownership stamp went with it" exists "$DELTA_STAMP"
fails "the remote branch is deleted" remote_has feature/delta

# feature/x-y and feature-x/y both map to <prefix>-feature-x-y. Landing the
# second must never remove the first one's tree, even with nothing to merge.
run "$APP" ./.claude/skills/create-worktree/create-worktree.sh feature/x-y
check "creates feature/x-y" 0
XY="$WS/legacy_name-feature-x-y"
echo "x-y in progress" > "$XY/wip.txt"
must git -C "$ORIGIN_BARE" branch feature-x/y main
run "$APP" "$MERGE" -m "chore: nothing to land" feature-x/y
check "refuses a worktree path that holds another branch" 1
says "and says the tree is not that branch's" "is not feature-x/y's worktree (no worktree has the branch checked out)"
holds "feature/x-y's worktree and its work are kept" test -f "$XY/wip.txt"
holds "feature-x/y is still on origin" remote_has feature-x/y
run "$APP" "$MERGE" -m "chore: nothing to land" feature/x-y "$WS/elsewhere"
check "refuses a path where the branch is not checked out" 1
says "and names where it is" "feature/x-y is checked out at $XY"
must git -C "$XY" submodule deinit -q -f --all
must git -C "$APP" worktree remove --force "$XY"
must git -C "$APP" branch -q -D feature/x-y
must git -C "$ORIGIN_BARE" branch -q -D feature-x/y

# ===================================================================
echo "merge-and-cleanup: the squash removes the repo's gate"
run "$APP" "$MERGE" -m "chore: drop the stub gate" feature/nogate
check "lands" 0
says "says the push runs the hook's inline gate" "No scripts/ci/pre-push-validate.sh in this repo: pushing main runs"
fails "the gate is gone from origin/main" git -C "$APP" cat-file -e origin/main:scripts/ci/pre-push-validate.sh
fails "the worktree is removed" exists "$NOGATE"
is "only the main worktree is left" "1" "$(git -C "$APP" worktree list | wc -l | tr -d ' ')"

# ===================================================================
echo "prune-stale-branches"
P="$TMP/prune"
PR="$P/repo"
must git init -q --bare "$P/origin.git"
must git init -q "$PR"
must git -C "$PR" remote add origin "$P/origin.git"
commit_file() { # <repo> <file> <content> <subject>
    printf '%s\n' "$3" > "$1/$2"
    must git -C "$1" add "$2"
    must git -C "$1" commit -qm "$4"
}
commit_file "$PR" base.txt base "chore: base"
M0=$(git -C "$PR" rev-parse HEAD)
must git -C "$PR" checkout -q -b pe "$M0"
commit_file "$PR" pe.txt pe "feat: pe"
must git -C "$PR" checkout -q main
must git -C "$PR" cherry-pick "$(git -C "$PR" rev-parse pe)"
must git -C "$PR" checkout -q -b sq "$M0"
commit_file "$PR" sq.txt a "feat: sq one"
commit_file "$PR" sq.txt $'a\nb' "feat: sq two"
must git -C "$PR" checkout -q main
must git -C "$PR" merge -q --squash sq
must git -C "$PR" commit -qm "feat: sq, squashed"
must git -C "$PR" checkout -q -b ct "$M0"
commit_file "$PR" ct.txt v1 "feat: ct one"
commit_file "$PR" ct.txt v2 "feat: ct two"
must git -C "$PR" checkout -q main
echo extra > "$PR/extra.txt"
must git -C "$PR" add extra.txt
commit_file "$PR" ct.txt v2 "feat: ct and more, in one commit"
must git -C "$PR" checkout -q -b um "$M0"
echo changed > "$PR/base.txt"
must git -C "$PR" add base.txt
commit_file "$PR" um.txt um "feat: um"
must git -C "$PR" checkout -q -b inuse "$M0"
commit_file "$PR" iu.txt iu "feat: in use"
must git -C "$PR" checkout -q main
must git -C "$PR" worktree add -q "$P/inuse-wt" inuse
must git -C "$PR" push -q origin main pe

run "$PR" "$APP/.claude/skills/finish-worktree/prune-stale-branches.sh"
check "a read-only sweep succeeds" 0
says "patch-equivalent: every commit has a twin on main" "merged     pe (patch-equivalent) — safe to delete"
says "squash: the whole diff is one commit on main" "merged     sq (squash) — safe to delete"
says "content: every touched file matches main" "merged     ct (content) — safe to delete"
says "unmerged work is reported" "UNMERGED   um"
says "with the file main lacks" "not on main:       um.txt"
says "and the file main has differently" "differs from main: base.txt"
says "a checked-out branch is never judged" "in use     inuse (checked out in a worktree)"
for b in pe sq ct um inuse; do
    holds "the read-only sweep kept $b" git -C "$PR" rev-parse -q --verify "refs/heads/$b"
done

run "$PR" "$APP/.claude/skills/finish-worktree/prune-stale-branches.sh" --apply . "$APP"
check "--apply over two repos succeeds" 0
says "sweeps the first repo" "=== repo"
says "and the second" "=== widget"
says "deletes the patch-equivalent branch" "deleted    pe (merged: patch-equivalent)"
says "deletes the squashed branch" "deleted    sq (merged: squash)"
says "deletes the content-identical branch" "deleted    ct (merged: content)"
for b in pe sq ct; do
    fails "$b is gone" git -C "$PR" rev-parse -q --verify "refs/heads/$b"
done
holds "the unmerged branch stays" git -C "$PR" rev-parse -q --verify refs/heads/um
holds "the branch in use stays" git -C "$PR" rev-parse -q --verify refs/heads/inuse
holds "origin's copy of a deleted branch stays" git -C "$PR" ls-remote --exit-code origin refs/heads/pe

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
