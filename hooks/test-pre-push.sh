#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Tests pre-push's shared-validation tier — a failure blocks with the full output, a pass shows its warnings
# ABOUTME: Real pushes against a throwaway bare remote, with a stand-in validate.sh; no network

set -u

HOOKS=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
check(){ # <desc> <expected-status> <actual-status>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected exit $2, got $3)"; fi
}
says() { # <desc> <text> <fixed-string>
    if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 — output lacks '$3': $2"; fi
}
lacks() { # <desc> <text> <fixed-string>
    if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 — output has '$3': $2"; else ok "$1"; fi
}

# Hermetic git, as in test-attribution.sh.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_EDITOR=true
printf '[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

# A repo on the inline gate (no scripts/ci/pre-push-validate.sh) with a stand-in for
# the shared validate.sh: it prints what STUB_OUT holds and exits STUB_RC. Each push
# changes only a workflow, so the hook runs the shared tier and then stops at its
# "no Rust in this push" exit, before fmt and clippy.
git init -q --bare "$TMP/remote.git"
mkdir -p "$TMP/repo/.build/validation" "$TMP/repo/.github/workflows" && cd "$TMP/repo" || exit 1
git init -q . && git config user.name "Ada Human" && git config user.email ada@example.com
git remote add origin "$TMP/remote.git"
printf '[package]\nname = "demo"\nversion = "0.1.0"\n' > Cargo.toml
cat > .build/validation/validate.sh <<'EOF'
#!/bin/bash
cat "$(dirname "$0")/stub-out"
exit "$(cat "$(dirname "$0")/stub-rc")"
EOF
printf '.build/\n' > .gitignore
git add Cargo.toml .gitignore && git -c core.hooksPath="$TMP/none" commit -qm "chore: seed"
git -c core.hooksPath="$TMP/none" push -q origin main 2>/dev/null

n=0
push_with() { # <stub output> <stub exit> — commits one workflow change and pushes it through the hook
    printf '%s\n' "$1" > .build/validation/stub-out
    printf '%s\n' "$2" > .build/validation/stub-rc
    n=$((n + 1))
    printf 'name: ci-%s\n' "$n" > .github/workflows/ci.yml
    git add .github/workflows/ci.yml && git -c core.hooksPath="$TMP/none" commit -qm "ci: change $n"
    OUT=$(git -c core.hooksPath="$HOOKS" push origin main 2>&1); RC=$?
}

echo "pre-push: shared validation tier"

push_with "$(printf '✅ No placeholder implementations\n⚠️  Found 1 test module layout problem(s) — those files were scanned whole\n✅ All architectural validations passed')" 0
check "a pass with a warning lets the push through" 0 "$RC"
says "and prints the warning" "$OUT" "⚠️  Found 1 test module layout problem(s)"
says "under a verdict that says it passed with warnings" "$OUT" "architectural validation passed with warnings"
lacks "without replaying the passing lines" "$OUT" "No placeholder implementations"

push_with "$(printf '✅ No placeholder implementations\n✅ All architectural validations passed')" 0
check "a clean pass lets the push through" 0 "$RC"
lacks "and prints no warning verdict" "$OUT" "passed with warnings"

push_with "$(printf '❌ Found 1 problematic .unwrap() calls\n❌ Architectural validation FAILED')" 1
check "a failure blocks the push" 1 "$RC"
says "and replays the full output" "$OUT" "Found 1 problematic .unwrap() calls"
says "with the block line" "$OUT" "BLOCKED: Architectural validation failed"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
