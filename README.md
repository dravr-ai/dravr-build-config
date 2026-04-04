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

## Extending

Create `validation-patterns.local.toml` in your repo root to add project-specific rules. Local rules extend (never weaken) the baseline.
