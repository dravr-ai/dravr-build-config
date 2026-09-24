---
name: register-limitation
description: Register a known gap in the limitation register — file the issue in the private tracker, write the LIMITATION(registre#n) marker, or ledger a dark-launched feature. Use when the register gates fail, or when you are about to document why something is incomplete.
user-invocable: true
---

# Register a Limitation

## When this fires

Any of these, without exception:

- The register gates failed — "unregistered deferral/confession prose" or "malformed LIMITATION marker".
- You are about to write a comment explaining why something is incomplete, restricted, or deferred.
- You are shipping a feature **disarmed** (flag off, shadow mode, log-only phase).
- You found a gap while reading code and are not fixing it in this change.

The gates are the Apache-2.0 [llm-registre](https://github.com/dravr-ai/llm-registre) tool,
vendored at `.build/vendor/llm-registre/` and run by this repo's validation script at pre-push
and in CI (`.build/validation/validate.sh`, or `scripts/ci/architectural-validation.sh` where a
repo has its own).

## Step 0 — try to not need this

The register exists so honest gaps become tracked obligations, **not** so gaps become easy to
ship. If you can implement the real thing now, do that instead. Registering is the fallback, and
it costs a permanent entry someone has to close later.

## Where issues go

**Read `registre.toml` at the repo root — its `tracker` key names this repo's register.** Never
assume; registers are per project. For the `dravr-*` family that is `dravr-ai/dravr-carnet`.

```bash
grep tracker registre.toml
```

| | |
|---|---|
| Tracker | whatever `registre.toml` says |
| Labels | `limitation` + this repo's name (e.g. `dravr-canot`) |
| Title | `[<project>] <short statement of the gap>` — always project-prefixed |

**Never file on the code repo itself.** Most are PUBLIC, and a limitation issue states precisely
where a defence is incomplete — a roadmap when the code is open.

Issue bodies may hold reasoning and residual risk; the code comment stays thin.

## Step 1 — file the issue

File it through the `carnet` skill's script — the one path into the register. It reads the
tracker from `registre.toml`, refuses a public tracker, derives the project from `origin` (a
worktree's basename is its branch, not a project), prefixes the title `[<project>] `, and adds
the project label. Pass `--label limitation` because a marker will point at this issue.

```bash
.claude/skills/carnet/carnet.sh create \
  --label limitation \
  --title "Short statement of the gap" \
  --body "Where it is (file + symbol). What is incomplete. What the correct fix looks like."
# → https://github.com/<tracker>/issues/42
#   marker: LIMITATION(registre#42): <name the limited item on this line>
```

Add `--claim` when you are about to keep working the gap in this session, so a peer sees it
held.

## Step 2 — write the marker

On the comment line that names the limited item:

```rust
/// LIMITATION(registre#42): `ChannelDescriptor::max_message_length` is not threaded through
/// `PlatformCommandContext`, so this is the cross-channel floor, not the per-channel value.
const PLAN_TEXT_BUDGET: usize = 2_000;
```

Rules that make a marker valid rather than decorative:

- The literal is `registre#<number>` — the bare word, never the tracker repo name. The tracker is
  configuration (`registre.toml`); the marker never changes when it moves.
- **Name the limited item on the marker line** (the symbol, variant, or endpoint). A marker that
  says only "this is incomplete" is unsearchable.
- The marker exempts **its own line** from the prose ban, not the file. A second unmarked deferral
  sentence on the next line still fails.
- **Put it in source the gates scan.** Test, bench, example and generated trees are outside the
  scan (`limitation-gates.sh --list-files` prints what is in), so a marker there is validated by
  nothing and never credits the issue as registered. A gap in test *coverage* belongs to the
  production item that goes uncovered: mark that item, where the next person to change it reads
  it — "LIMITATION(registre#42): the live eval lane never executes `assemble_prompt`, so …".

## Step 3 — if the feature ships disarmed, ledger it too

Add to `feature-phases.yaml` (fixed shape — the review workflow parses it with `awk`):

```yaml
  - name: kebab-case-feature-name
    surface: src/path/to/the/flag/or/mode.rs
    current: what ships today, i.e. the disarmed state
    advance_when: the criterion that arms the next phase
    review_by: 2026-09-30
```

A weekly workflow opens a `feature-phase` issue in the tracker once `review_by` passes, so phase 1
cannot silently become forever. Keep values free of `": "` and `" #"`.

## Step 4 — verify

```bash
.build/vendor/llm-registre/limitation-gates.sh crates src        # scan dirs this repo has
./.build/validation/validate.sh                                  # or the full validation run
.build/vendor/llm-registre/limitation-gates.sh --verify-tracker  # online: needs gh with read access to the tracker
```

Expect every gate green. In dravr-platform, `scripts/ci/architectural-validation.sh` runs the
same gates plus a repo-specific phantom-capability check.

The offline gates check the marker's *shape* only. `--verify-tracker` (gate 6) also checks the
other half of the pair: every marker in scope must name an issue that exists on the tracker, is
open, and carries the `limitation` label. It reads the tracker over GitHub REST, so pre-push does
not run it; a repo that holds a tracker read token runs it on a schedule (dravr-platform:
`Monitor: Limitation Register Reconciliation`, weekly), and you can run it by hand with your own
`gh` login before you push.

## Closing an entry

Fix the gap, **delete the marker in the same change**, close the issue. A stale marker still
exempts prose from the gates, so exhausted markers are debt of their own — and an issue closed
while its marker stays fails gate 6 the next time it runs, naming the file and line.

## Consume what you declare

A capability predicate, enum variant, or trait method whose only callers are tests is a phantom
surface. Wire a production consumer in the same change, or register it here with a marker naming
the item. CI enforces this for the canot messaging surface (`supports_*` / `max_*` predicates,
`MessageContent` variants).

## What the register does not cover

Gates 1–5 are per-change and gate 6 reconciles only what was marked: they stop new debt at
authoring time and keep the marked inventory honest, but cannot reach the standing
stock of defects that live between diffs — a handler nothing reaches, an override nothing reads,
two components each locally correct and jointly wrong. Those come out of periodic adversarial
cold-reads and get filed here like anything else. A green gate means no new unregistered debt, not
a clean codebase.
