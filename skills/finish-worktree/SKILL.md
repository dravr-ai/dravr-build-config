---
name: finish-worktree
description: Completes feature branch work by rebasing, pushing, monitoring CI, and squash merging to main
user-invocable: true
---

# Finish Worktree Skill

**CLAUDE: When this skill is invoked with `/finish-worktree`, immediately run:**
```bash
./.claude/skills/finish-worktree/finish-worktree.sh
```
**Then watch CI, and once every lane is green, land the branch with `merge-and-cleanup.sh`.**

## Purpose
Lands a feature branch the way every dravr repo lands everything: rebase onto `origin/main`,
the local pre-push gate, a push, CI green, then a squash merge that advances the one shared
`main` ref, followed by cleanup of the branch and its worktree. No pull request.

Shared from `dravr-build-config` (`.build/skills/finish-worktree`), so the same scripts run in
every repo. Nothing in them names a repository: the GitHub repo comes from `origin`, the gate
from whether the repo carries one, and the worktree layout from `create-worktree`'s rules.

## Usage
```bash
/finish-worktree
```

## Workflow Steps

### Step 1: Rebase, gate, push (in the feature worktree)
```bash
./.claude/skills/finish-worktree/finish-worktree.sh
```

The script refuses a detached HEAD, `main`, and uncommitted changes; fetches and rebases
onto `origin/main` (stopping on a conflict for you to resolve); runs the gate; pushes with
`--force-with-lease`; and saves the branch and worktree for Step 4.

The gate is `scripts/ci/pre-push-validate.sh` when the repo has one — dravr-platform's own,
or a satellite's wrapper around `.build/validation/satellite-pre-push-validate.sh` — and it
writes the per-commit marker the pre-push hook checks. A repo without one is validated by
`.build/hooks/pre-push`'s inline gate during the push itself (validate.sh, then fmt and
clippy on the changed crates); the script says so, and refuses outright when that hook is
not armed either (run `bash .build/ci/bootstrap-repo.sh`).

### Step 2: Watch CI
The script prints the exact commands for this repo. Use the first available method, and
**never ask for a GitHub token**:
1. `gh run list --repo <owner>/<repo> --branch <branch>` and `gh run view <id>` for one run;
   re-check on a schedule (`ScheduleWakeup`), never `gh run watch` and no loop under 60 seconds.
2. GitHub MCP tools (`mcp__github__*`) for anything that is not a listing.
3. WebFetch `https://github.com/<owner>/<repo>/actions?query=branch%3A<branch>`.

Wait until every lane is terminal and green. A cancelled run is not a verdict, and neither is
a lane that did not run: some repos run a reduced suite for some ref names (dravr-platform
runs the full PostgreSQL suite on `feature/*` and only an 8-file smoke on `fix/*`).

### Step 3: If CI fails
Fix the cause locally, validate the crate you touched, commit, and push again:
```bash
CARGO_BUILD_WARNINGS=deny cargo clippy -p <crate> --all-targets --all-features   # the crate you changed
cargo test -p <crate> --test <file> <name>                                     # the test that failed
git add <the files you changed>
git commit
./.claude/skills/finish-worktree/finish-worktree.sh                              # gate + push again
```
Do not run the full-workspace clippy locally as a gate; CI does that on every push. Repeat
until every lane is green.

### Step 4: Squash merge and cleanup (from the main worktree, on `main`)
```bash
cd /path/to/main/worktree
./.claude/skills/finish-worktree/merge-and-cleanup.sh -m "<subject>

<body: what changed and why>"
```

No branch arguments needed: the script reads what Step 1 saved (`-F <file>` also works;
an interactive run with neither opens the editor prefilled with the branch's commit
subjects). It merges exactly the pushed `origin/<branch>`, the ref CI validated.

It refuses, with the reason printed:
- when it is not on `main` in the main worktree;
- when the repo has neither a gate script nor an armed pre-push hook;
- when uncommitted changes in the main worktree overlap the branch's files (someone's
  work in progress would be swallowed; non-overlapping unstaged work is left alone);
- when anything is staged in the main worktree: the squash commit takes the whole index,
  so a peer's `git add` would reach `origin/main` under your message;
- when the worktree it would remove is not the one git has the branch checked out in
  (`feature/a-b` and `feature-a/b` share one directory name), or holds changes no commit
  has — `git worktree remove --force` would destroy them. It checks before the squash
  and again before the removal; the second time it stops with exit 3, the work already on
  `origin/main`, and prints the rerun;
- when local `main` cannot fast-forward to `origin/main`, or carries commits `origin/main`
  lacks (unpushed commits or a divergence need a person);
- when `origin/main` moved while the gate ran, or the push is rejected: the squash
  commit stays on local `main`, the recovery commands are printed, and **nothing is
  cleaned up**. Cleanup runs only once the work is on `origin/main`, and the remote
  branch is deleted last. Once you have landed the squash with the printed commands,
  rerun the script: it finds nothing left to merge and only cleans up.

A squash that moves `.build` is validated on the new `.build`: the script runs
`git submodule update --init --recursive` before the gate, because a merge never moves a
submodule checkout.

The commit message is yours alone: no trailers, no attribution. The commit-msg hook
enforces a subject of at most 72 characters followed by a blank line.

Cleanup: `submodule deinit` then `git worktree remove --force` (a worktree from
`create-worktree` carries the `.build` submodule), `git branch -D` (a squash is not seen
as a merge), and `git push origin --delete` last.

### Step 5: Watch main
The push is the start of validation, not the end. Watch main's lanes for the landed
commit until they are terminal; a red one is yours to fix in the same session.

### Step 6: Prune what other sessions left behind
Step 4 deletes your own branch, but a squash merge never marks a branch merged, so
every session that lands without cleaning up leaves one behind — and sessions that
died leave their worktree and `target/` too. Sweep every repo you touched — this one and
any sibling dravr repo the change reached — read-only first:
```bash
./.claude/skills/finish-worktree/prune-stale-branches.sh . ../dravr-cageux ../dravr-tronc
./.claude/skills/finish-worktree/prune-stale-branches.sh --apply . ../dravr-cageux ../dravr-tronc
```
It deletes a branch only when its work is provably on `main` — every commit
patch-identical there, its whole diff matching one squash commit, or every file it
touched byte-identical on `main` — and never a branch checked out in a worktree (a
session is using it). A git call that fails proves nothing, so that branch stays. Do not
use a `merge-tree` trial merge as the test: it conflicts whenever `main` changed the same
lines again later and flags work that landed months ago. An `UNMERGED` branch is printed
with its commits and files: port what is still valid into your change (a half that
targets a deleted module is dead), or ask whoever owns the work. A branch whose copy is on
`origin` loses nothing when deleted locally; never delete someone else's remote branch
without asking.

**Disk.** A worktree's `target/` is yours to clean when you are done with it:
`git worktree remove` deletes it, and a worktree you keep can drop
`target/debug/incremental` (rebuildable). Parallel agents building one workspace in one
worktree grew it to 300 GB and filled the disk for every session on the machine — export
`CARGO_INCREMENTAL=0` for agent builds and run one workspace build at a time. Where the
repo ships a sweep (dravr-platform: `./scripts/setup/cargo-sweep-nightly.sh status`, against
its fleet cap), check it before a long build.

## Complete Example Session
```bash
# In the feature worktree
./.claude/skills/finish-worktree/finish-worktree.sh

# Watch CI (Step 2). If red, fix and push again (Step 3). Once green:
cd /path/to/main/worktree
./.claude/skills/finish-worktree/merge-and-cleanup.sh -m "feat(sdk): the bridge speaks MCP 2026-07-28

The client leg moves onto a stateless client; the host side stays on the official SDK."

# Then watch main (Step 5), and prune the leftovers (Step 6).
./.claude/skills/finish-worktree/prune-stale-branches.sh --apply . ../dravr-cageux
```

## Related Skills
- `create-worktree` - Creates the worktree this skill lands, in the layout it expects
