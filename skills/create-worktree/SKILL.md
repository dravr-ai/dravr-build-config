---
name: create-worktree
description: Creates a git worktree with branch and copies environment files (.envrc, .mcp.json)
argument-hint: [branch-name]
user-invocable: true
---

# Create Worktree Skill

**CLAUDE: When this skill is invoked with `/create-worktree <branch-name>`, immediately run:**
```bash
./.claude/skills/create-worktree/create-worktree.sh <branch-name>
```

## Purpose
Creates a new git worktree with a feature branch, ready to commit and push: the `.build`
submodule checked out (without it the git hooks silently do not run), the untracked
environment files copied, and the worktree stamped as this session's.

Shared from `dravr-build-config` (`.build/skills/create-worktree`), so it behaves the same in
every dravr repo.

## Usage
```bash
/create-worktree feature/my-new-feature
```

## What It Does
1. Creates branch `<branch-name>` from the current HEAD in a new worktree at
   `<parent of the main worktree>/<prefix>-<branch, / as ->` (layout below)
2. Runs `git submodule update --init --recursive` there, and refuses to finish when
   `.build/hooks/commit-msg` is missing
3. Stamps the worktree's git-dir with this session's id (`claude-session`), for the status line
4. Copies `.envrc` and `.mcp.json` from the main worktree when it has them (a repo without
   them skips this step silently)
5. Runs `direnv allow` when it copied an `.envrc` and direnv is installed

## Worktree layout
`<prefix>` is the main worktree's directory name, so `dravr-cageux` on branch
`fix/login` gets `../dravr-cageux-fix-login`. A repo whose existing worktrees follow
another name commits `.claude/worktree.conf` with a `prefix` key:

```
# Feature worktrees are <parent of the main worktree>/<prefix>-<branch>.
prefix = pierre_mcp_server
```

dravr-platform carries exactly that: its worktrees predate the rename and carry the old name
on every machine. `merge-and-cleanup.sh` reads the same file, so a branch named on its command
line resolves to the same directory. A prefix must be one plain directory name
(`A-Z a-z 0-9 . _ -`); anything else is refused.

## Commands

### Using the script directly:
```bash
./.claude/skills/create-worktree/create-worktree.sh <branch-name> [optional-path]

# Examples:
./.claude/skills/create-worktree/create-worktree.sh feature/new-api
./.claude/skills/create-worktree/create-worktree.sh fix/bug-123 /tmp/quick-fix
```

### Manual steps (if script unavailable):
```bash
BRANCH="feature/my-feature"
WORKTREE="../$(basename "$PWD")-${BRANCH//\//-}"   # or the prefix from .claude/worktree.conf

git worktree add -b "$BRANCH" "$WORKTREE"
git -C "$WORKTREE" submodule update --init --recursive
[ -f .envrc ] && cp .envrc "$WORKTREE/"
[ -f .mcp.json ] && cp .mcp.json "$WORKTREE/"
```

## Cleanup
Landing through `finish-worktree` removes the worktree and deletes the branch. By hand:
```bash
git -C ../<prefix>-feature-my-feature submodule deinit -f --all
git worktree remove --force ../<prefix>-feature-my-feature
git branch -D feature/my-feature  # a squash merge is not seen as a merge
```

## Related Skills
- `finish-worktree` - Completes feature branch work with rebase, gate, CI, squash merge and cleanup
