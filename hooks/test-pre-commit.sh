#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Tests the pre-commit hook's backwards-submodule guard by making it fire
# ABOUTME: Builds a throwaway superproject + submodule; no network, no fixtures

set -u

HOOK=$(cd "$(dirname "$0")" && pwd)/pre-commit
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
check(){ # <desc> <expected-status> <actual-status>
    [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected exit $2, got $3)"
}

G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c protocol.file.allow=always"

# --- a submodule with three commits: A -> B -> C -------------------------
mkdir -p "$TMP/sub" && cd "$TMP/sub" && $G init -q .
for n in A B C; do echo "$n" > f.txt; $G add f.txt; $G commit -qm "$n"; done
A=$($G rev-parse HEAD~2); B=$($G rev-parse HEAD~1); C=$($G rev-parse HEAD)

# --- a superproject pinning the submodule at B ---------------------------
mkdir -p "$TMP/super" && cd "$TMP/super" && $G init -q .
echo seed > seed.txt && $G add seed.txt && $G commit -qm seed
$G submodule add -q "$TMP/sub" sub 2>/dev/null
$G -C sub checkout -q "$B"
$G add sub && $G commit -qm "pin sub at B"
[ "$($G rev-parse HEAD:sub)" = "$B" ] || { echo "setup failed"; exit 1; }

stage_sub_at() { $G -C sub checkout -q "$1"; $G add sub; }
reset_index()  { $G reset -q; $G -C sub checkout -q "$B"; }

echo "pre-commit submodule guard"

# 1. rewind alongside other work — the real failure, must be refused
reset_index; stage_sub_at "$A"; echo x > other.txt; $G add other.txt
out=$(bash "$HOOK" 2>&1); st=$?
check "refuses a rewind staged with other work" 1 "$st"
printf '%s' "$out" | grep -q "move BACKWARDS 1 commit" \
    && ok "names the direction and the distance" \
    || bad "message did not say how far back: $out"
printf '%s' "$out" | grep -q "git restore --staged sub" \
    && ok "prints the repair command" || bad "no repair command"
rm -f other.txt

# 2. deliberate rollback — submodule alone is allowed
reset_index; stage_sub_at "$A"
out=$(bash "$HOOK" 2>&1); st=$?
check "allows a rollback staged by itself" 0 "$st"
printf '%s' "$out" | grep -q "submodule staged alone" \
    && ok "says why it was allowed" || bad "no explanation: $out"

# 3. a forward bump is never touched
reset_index; stage_sub_at "$C"; echo y > other.txt; $G add other.txt
check "allows a forward bump with other work" 0 "$(bash "$HOOK" >/dev/null 2>&1; echo $?)"
rm -f other.txt

# 4. two commits back is reported as two
reset_index; $G -C sub checkout -q "$C"; $G add sub; $G commit -qm "pin C"
$G -C sub checkout -q "$A"; $G add sub; echo z > other.txt; $G add other.txt
out=$(bash "$HOOK" 2>&1)
printf '%s' "$out" | grep -q "BACKWARDS 2 commit" \
    && ok "counts the dropped commits" || bad "wrong count: $out"
$G reset -q --hard HEAD~1 >/dev/null 2>&1; rm -f other.txt

# 5. an uninitialized submodule warns, but never blocks a commit
reset_index; stage_sub_at "$A"; echo w > other.txt; $G add other.txt
mv sub/.git "$TMP/sub-git-stash"
out=$(bash "$HOOK" 2>&1); st=$?
mv "$TMP/sub-git-stash" sub/.git
check "does not block when the submodule is not checked out" 0 "$st"
printf '%s' "$out" | grep -q "direction unverified" \
    && ok "says the direction could not be checked" || bad "passed in silence: $out"

# 6. a linked worktree: git hands the hook the worktree's GIT_DIR and index, which
#    `git -C sub` kept, so every pointer read as missing and nothing was checked
reset_index
$G worktree add -q "$TMP/wt" 2>/dev/null
cd "$TMP/wt" && $G submodule update -q --init 2>/dev/null
WT_GIT_DIR=$($G rev-parse --absolute-git-dir)
$G -C sub checkout -q "$A"; $G add sub; echo v > other.txt; $G add other.txt
out=$(GIT_DIR="$WT_GIT_DIR" GIT_INDEX_FILE="$WT_GIT_DIR/index" bash "$HOOK" 2>&1); st=$?
check "refuses a rewind in a linked worktree" 1 "$st"
printf '%s' "$out" | grep -q "direction unverified" \
    && bad "the worktree's GIT_DIR hid the submodule: $out" \
    || ok "reads the submodule's own objects from a worktree"
cd "$TMP/super" || exit 1

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
