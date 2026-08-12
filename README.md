# dravr-build-config

Shared build configuration, lint rules, and architectural validation for all dravr-* Rust projects.

## Quick Start

```bash
# Add to your repo
git submodule add https://github.com/dravr-ai/dravr-build-config .build
git config core.hooksPath .build/hooks

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
- `ci/` — Reusable CI helpers
- `docs/AGENTS_DISCIPLINE.md` — Shared architectural discipline rules for AI agents
- `skills/` — Claude Code skills shared across repos; symlink them into your `.claude/skills/`
- `vendor/llm-registre/` — submodule: the [llm-registre](https://github.com/dravr-ai/llm-registre)
  limitation-register gates, run by `validate.sh`

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
