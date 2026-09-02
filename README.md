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
- `hooks/` — Git hooks (pre-commit, commit-msg)
- `ci/` — Reusable CI helpers, plus `bootstrap-repo.sh` (see below)
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

## Shared skills

`skills/` ships Claude Code skills every consumer exposes through a symlink in its
`.claude/skills/` (`bootstrap-repo.sh` creates the links; commit them). Each is a `SKILL.md`,
optionally with the script it wraps.

| Skill | Purpose |
|---|---|
| `carnet` | the register from the command line: `claim`, `release`, `status`, `mine`, `create`, `close`, `label`. A claim = assignee + `in-progress` label + a marker comment naming the Claude Code session, so a peer session sees who holds an issue before starting the same work. Two hooks make it automatic — see below. |
| `register-limitation` | file a limitation issue (through `carnet create`), write the `LIMITATION(registre#n)` marker, ledger a dark launch |

### carnet hooks

Add to the consumer repo's `.claude/settings.json`. The prompt hook prints the live claim
status of every issue a prompt names into the model's context; the session-end hook releases
whatever the session still holds. Both exit 0 on every failure.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [ { "type": "command", "timeout": 20,
        "command": "[ -f .build/skills/carnet/hooks/prompt-status.sh ] && bash .build/skills/carnet/hooks/prompt-status.sh || true" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "timeout": 30,
        "command": "[ -f .build/skills/carnet/hooks/session-end-release.sh ] && bash .build/skills/carnet/hooks/session-end-release.sh || true" } ] }
    ]
  }
}
```

`skills/carnet/test.sh` runs the whole skill against a stub `gh`; `.github/workflows/test.yml`
runs it on every push here.

## Limitation register

`validate.sh` runs the llm-registre gates: deferral prose ("is the follow-up", "not yet wired")
is banned unless the line carries a `LIMITATION(registre#n):` marker naming the limited item and
pointing at a filed issue, and dark-launched features need a `feature-phases.yaml` entry with a
review date. Point it at your tracker with a `registre.toml` at your repo root:

```toml
tracker        = "dravr-ai/carnet"
require_ledger = true
```

Because it is a nested submodule, clone and CI checkout must be **recursive**
(`git submodule update --init --recursive`, `submodules: recursive` in actions/checkout).

## Extending

Create `validation-patterns.local.toml` in your repo root to add project-specific rules. Local rules extend (never weaken) the baseline.
