<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 dravr.ai
ABOUTME: Shared architectural discipline rules for all dravr-* repos
ABOUTME: Append to each repo's AGENTS.md via `cat .build/docs/AGENTS_DISCIPLINE.md >> AGENTS.md`
-->

# Shared Architectural Discipline (canonical)

This file is the **single source of truth** for session startup, architectural
discipline, and pushback rules across all dravr-* repositories. Each repo's
`AGENTS.md` should either reference or include this content.

To apply to a new repo:
```bash
cat .build/docs/AGENTS_DISCIPLINE.md >> AGENTS.md
git add AGENTS.md
git commit -m "docs: add shared architectural discipline from dravr-build-config"
```

---

## Mandatory Session Startup Checklist

Before touching any code in a new session, run in this order:

```bash
# 1. Pull shared build config (provides .build/hooks, .build/validation, etc.)
git submodule update --init --recursive

# 2. Set canonical git hooks path — ALWAYS .build/hooks, NEVER .githooks
git config core.hooksPath .build/hooks

# 3. Scan recent history for context
git log --oneline -10

# 4. Check CI health on main
gh run list --branch main --limit 10 --json workflowName,conclusion

# 5. See uncommitted work
git status
```

**If any workflow on main has been red for 2+ runs, STOP and surface it to the user** before starting the requested task. Ask: "Should I investigate CI before doing X?"

The canonical hooks/validation live in the `.build/` git submodule from
https://github.com/dravr-ai/dravr-build-config — never use a local `.githooks/`.

## Architectural Discipline

### Single Source of Truth (SSOT)
Before adding a new abstraction (registry, manager, factory, handler, schema module):
1. Grep for existing abstractions with similar purposes
2. If one exists, USE IT or DOCUMENT WHY it's being replaced + DELETE the old in the same commit
3. Never leave two systems doing the same job "for compat"

### No Orphan Migrations
If you introduce a "v2" of something:
- Migrate ALL callers in the same session, OR
- Record remaining work in memory (`type: project`) with explicit list of what's left
- NEVER leave "for compat" code without a tracked deletion date

### When Adding, Remove
Every commit that adds a new abstraction must identify what it replaces and delete that. If nothing is replaced, the commit message must justify why the new abstraction is needed.

### Complete Deletion, Not Deprecation
Don't mark code `// DEPRECATED` or `// TODO remove later`. Delete it. If deletion is blocked, file an issue and link it from the code.

## Pushback Triggers — When to Stop and Ask

STOP and ask the user before proceeding when you find:

1. **Duplication** — two systems/modules doing similar things
   → "Is this intentional? Should I consolidate before adding my feature?"
2. **Stale state** — `TODO`, `FIXME`, `for compat`, `temporary`, `v2` comments in code you're touching
   → "Is this still needed? Should I resolve it first?"
3. **Red CI** — workflows failing on main
   → "Should I fix CI first before doing the task?"
4. **Version drift** — two versions of the same dependency in Cargo.lock
   → "Is this intentional or should it be consolidated?"
5. **Request conflicts with architecture** — user asks you to add X but X exists differently
   → Surface the existing thing, ask which to use
6. **Half-finished migrations** — both old and new paths still live
   → "Finish migration first, or add feature on top?"

Default behavior is to complete the requested task. These triggers override that.
