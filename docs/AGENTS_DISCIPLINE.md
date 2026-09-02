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

## Working an Issue in the Register

Two humans run many Claude Code sessions at once against one private register, so an issue
must say who holds it and which session. The `carnet` skill (`.claude/skills/carnet/carnet.sh`)
is the only path into the tracker — never `gh issue` by hand.

1. **Claim before the first edit — the hooks do it without you.** Any issue a prompt named is
   claimed on your first write-shaped tool call: assignee, `in-progress`, and a marker naming
   this session. Run `carnet.sh claim <n>` yourself only when the number never appeared in a
   prompt — you found it by searching, or you are picking work up mid-session.
2. **Exit code 2 is a peer.** Another live session holds it, or a session on another host
   does. Name them to the user and stop. `--steal` is the user's decision, never yours. The
   auto-claim hook blocks one tool call to tell you this, then stops — after that the
   duplicate work is yours, not the hook's.
3. **Release or close when you stop.** `release <n>` on hand-off or abandonment;
   `close <n> --why "…" --commit <sha>` when it landed. `--why` is mandatory — a commit
   message saying `carnet#n` is plain text to GitHub and closes nothing across repos.
4. **File through `create`.** Title `[<project>] <Thing>`, project label, private tracker —
   the script enforces all three. `limitation` only when a `LIMITATION(registre#n)` marker
   will point at the issue.

The prompt hook prints the claim status of every issue you mention; the session-end hook
releases what a session forgot. Neither replaces rule 1.
