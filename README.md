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

Wire it into `.claude/settings.json` as a `SessionStart` hook. The `[ -f ]` guard is
load-bearing: a `.build` pinned *before* this script existed cannot run it, so the
fallback checks out the pinned revision first (skipped when `.build` is on a branch,
so in-progress work is never detached):

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "[ -f .build/ci/bootstrap-repo.sh ] || git -C .build symbolic-ref -q HEAD >/dev/null 2>&1 || git submodule update --init --recursive -q 2>/dev/null; [ -f .build/ci/bootstrap-repo.sh ] && bash .build/ci/bootstrap-repo.sh || true"
      } ] }
    ]
  }
}
```

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
