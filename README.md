# dravr-build-config

Shared build configuration, lint rules, and architectural validation for all dravr-* Rust projects.

## Quick Start

```bash
# Add to your repo
git submodule add https://github.com/dravr-ai/dravr-build-config .build
bash .build/ci/bootstrap-repo.sh   # hooks, submodule auto-sync, shared skills

# Symlink configs
ln -sf .build/cargo/clippy.toml clippy.toml
ln -sf .build/cargo/rustfmt.toml rustfmt.toml

# Run validation
.build/validation/validate.sh

# Append shared AI-agent discipline rules to your AGENTS.md
cat .build/docs/AGENTS_DISCIPLINE.md >> AGENTS.md
```

## Structure

- `cargo/` — Canonical Cargo lint config, clippy.toml, rustfmt.toml, deny.toml
- `validation/` — Architectural validation script + pattern definitions
- `hooks/` — Git hooks (pre-commit, commit-msg, pre-push); `ai-attribution.sh` holds the rules the last two share
- `ci/` — Reusable CI helpers, plus `bootstrap-repo.sh` (see below)
- `.github/workflows/` — reusable workflows every satellite calls: `release-crate.yml` and
  `notify-release.yml` (see below)
- `docs/AGENTS_DISCIPLINE.md` — Shared architectural discipline rules for AI agents
- `skills/` — Claude Code skills shared across repos; symlink them into your `.claude/skills/`
- `vendor/llm-registre/` — submodule: the [llm-registre](https://github.com/dravr-ai/llm-registre)
  limitation-register gates, run by `validate.sh`

## Keeping `.build` in sync (`ci/bootstrap-repo.sh`)

Git does **not** update a submodule when you pull the superproject unless
`submodule.recurse` is set. A pull that advances the `.build` gitlink therefore leaves
`.build/` at the old revision, and everything resolving *through* it degrades silently:
`core.hooksPath` finds no hooks (so commits and pushes run unvalidated and look clean),
`validate.sh` loses the register gates, and any `.claude/skills` symlink into
`.build/skills` dangles — a dangling skill symlink raises no error, the skill simply
stops existing.

`bootstrap-repo.sh` is the cure and the vaccine. It sets the git config that makes
future pulls self-heal, then repairs the current checkout:

| Setting | Effect |
|---|---|
| `submodule.recurse=true` | pull/checkout/switch/merge/rebase/reset update `.build` |
| `fetch.recurseSubmodules=on-demand` | a moved gitlink fetches the commit it now points at |
| `push.recurseSubmodules=check` | refuses to push a gitlink whose `.build` commit is not on the remote |
| `core.hooksPath=.build/hooks` | hooks resolve, in worktrees too |

It then checks out a missing or stale submodule (nested `vendor/` included), symlinks
every `skills/` entry this repo does not already define, and reports dead symlinks and
missing hooks. It **never** moves a `.build` that is dirty or on a branch — it warns
instead — and it always exits 0, because a session-start hook that fails tells you
nothing useful.

Wire it into `.claude/settings.json` as a `SessionStart` hook. Every guard in that
one-liner is load-bearing, because a script that lives inside the submodule cannot
be the thing that checks the submodule out:

- `[ -f .build/ci/bootstrap-repo.sh ]` — a `.build` pinned *before* this script
  existed cannot run it, so the fallback must check out the pinned revision first.
- `[ -e .build/.git ]` — **required before the `symbolic-ref` test.** On an
  uninitialized submodule `.build/` is an empty directory, so `git -C .build`
  silently walks up and answers about the *parent* repo, which always has a branch.
  Without this test the branch guard misfires exactly when `.build` is missing
  entirely — a fresh clone or a new worktree, the cases that most need repairing.
- `symbolic-ref` — skips the checkout when `.build` really is on a branch, so
  in-progress work there is never detached.

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "[ -f .build/ci/bootstrap-repo.sh ] || { [ -e .build/.git ] && git -C .build symbolic-ref -q HEAD >/dev/null 2>&1; } || git submodule update --init --recursive -q 2>/dev/null; [ -f .build/ci/bootstrap-repo.sh ] && bash .build/ci/bootstrap-repo.sh || true"
      } ] }
    ]
  }
}
```

### The rewind guard

`bootstrap-repo.sh` keeps a *pull* from leaving `.build` behind. It cannot help with the
other direction: a **squash merge from a branch forked before a `.build` bump** carries
that branch's older gitlink and records it over the newer one. Nothing fails — `.build/`
just becomes the old revision, and everything resolving through it degrades in the silence
described above. On 2026-09-02 that removed the `carnet` skill from eight of nine live
Claude Code sessions for three hours; the only symptom was a `DEAD symlink` line in the
session-start banner.

So `hooks/pre-commit` refuses a commit that moves a submodule pointer to an **ancestor** of
the current one:

```
❌ .build would move BACKWARDS 1 commit(s):
     dbbb7eae  →  19315089
   Keep the newer pointer:
     git restore --staged .build && git submodule update --init --recursive .build
```

A deliberate rollback stays possible — stage the submodule by itself and the guard warns
instead of refusing. When the submodule is not checked out the direction cannot be
determined, and the hook says so rather than passing quietly. `hooks/test-pre-commit.sh`
makes every one of those paths fire.

## No AI attribution

A commit credits only the human who makes it. `hooks/commit-msg` refuses a commit whose author
or committer (`git var GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT`) is named exactly `Claude` or
has an `@anthropic.com` address, and a message line matching `hooks/ai-attribution.sh`: a
Co-Authored-By for Claude or Anthropic, `Generated with`, 🤖, a `Claude-Session:` trailer, a
`claude.ai/code` link, or `noreply@anthropic.com`. It runs for `git commit` (with `--amend` and
after `merge --squash`) and for `git merge` itself, which never runs pre-commit. Cherry-pick,
revert, rebase and `commit --no-verify` run no commit hook, so `hooks/pre-push` judges again every
pushed commit that no remote has yet, lists each offending sha with the reason, and prints the
amend or rebase that fixes it; history already on a remote never blocks a push.
`hooks/test-attribution.sh` makes each path fire.

## Reusable release workflows

Every dravr-* satellite cuts its releases through `release-crate.yml` and announces them
through `notify-release.yml`, called at `@main` like dravr-tronc's `consumer-bump.yml`: a fix
here reaches every repo's next release with no pin to move. A public repo's workflows are
callable from the org's private repos. `test.yml` runs actionlint over both on every push.

`release-crate.yml` bumps the root crate and its lockstep members (their `[package]` version
and every `path` + `version` requirement one places on another), verifies the result, updates
only the workspace entries of `Cargo.lock`, prepends a `CHANGELOG.md` entry when the repo keeps
one, points the README's dependency snippets at the new version, commits, and pushes `main` and
the tag in **one `git push --atomic`**, so an orphaned tag cannot happen. It then publishes to
crates.io and creates the GitHub release.

| Input | Meaning |
|---|---|
| `bump` | `patch`, `minor` or `major` |
| `members` | member directories released in lockstep with the root crate |
| `publish` | crates to publish to crates.io, in dependency order; empty publishes nothing |
| `check` | a command the bumped tree must pass before it is committed |
| `ci_workflow` | refuse to release while main's latest run of this CI is not green (grant `actions: read`) |
| `private_git_deps` | resolve private dravr-ai git dependencies with the `RELEASE_PAT` secret |
| `tag` | republish an existing tag to crates.io: no bump, no commit, no GitHub release |

Secrets: `CARGO_REGISTRY_TOKEN` (with `publish`), `RELEASE_PAT` (with `private_git_deps`).
Outputs: `version` (no `v` prefix) and `prev_tag`. The caller grants `contents: write`, and keeps
its repo-specific jobs (binaries, images, Homebrew) behind `needs:` on the calling job.

```yaml
jobs:
  release:
    uses: dravr-ai/dravr-build-config/.github/workflows/release-crate.yml@main
    with:
      bump: ${{ inputs.bump }}
      members: crates/dravr-foo-mcp crates/dravr-foo-server
```

`notify-release.yml` sends one `repository_dispatch` with `{ version, sha }`: the version without
its `v` prefix and the commit its tag names. Inputs: `event` (the receiving lane's event type),
`version` (empty announces the latest release) and `repository` (default
`dravr-ai/dravr-platform`); secret `DISPATCH_TOKEN`.

## Shared skills

`skills/` ships Claude Code skills every consumer exposes through a symlink in its
`.claude/skills/` (`bootstrap-repo.sh` creates the links; commit them). Each is a `SKILL.md`,
optionally with the script it wraps.

A skill only belongs here when more than one repo uses it. A submodule needs a second update
step to move, so a consumer can sit on the newest commit and still resolve the skill through a
stale `.build` — the symlink dangles and the skill silently stops existing. `carnet` was moved
out to `dravr-platform/.agents/skills/carnet/` on 2026-09-02 for exactly that reason: it was
only ever used by that one repo, so the submodule bought nothing and cost that failure.

| Skill | Purpose |
|---|---|
| `register-limitation` | file a limitation issue (through `carnet create`), write the `LIMITATION(registre#n)` marker, ledger a dark launch |

## Limitation register

`validate.sh` runs the llm-registre gates: deferral prose ("is the follow-up", "not yet wired")
is banned unless the line carries a `LIMITATION(registre#n):` marker naming the limited item and
pointing at a filed issue, and dark-launched features need a `feature-phases.yaml` entry with a
review date. Point it at your tracker with a `registre.toml` at your repo root:

```toml
tracker        = "dravr-ai/carnet"
require_ledger = true
```

Those gates check a marker's shape. `limitation-gates.sh --verify-tracker` also checks that every
marker names an issue that exists on the tracker, is open, and carries the `limitation` label. It
reads the tracker over GitHub REST, so `validate.sh` never runs it at pre-push; a repo holding a
tracker read token runs it from a scheduled workflow instead.

Because it is a nested submodule, clone and CI checkout must be **recursive**
(`git submodule update --init --recursive`, `submodules: recursive` in actions/checkout).

## Extending

Create `validation-patterns.local.toml` in your repo root to add project-specific rules. Local rules extend (never weaken) the baseline.
