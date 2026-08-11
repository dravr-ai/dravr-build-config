#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Shared limitation-register gates for all dravr-* repos: deferral/confession
# ABOUTME: prose ban, LIMITATION(registre#n) marker format, feature-phase ledger format

# WHY: an honest gap documented in a factually-worded comment is invisible debt —
# dravr-platform's 2026-08 audit found a text-budget floor and a whole capability
# surface hidden for months behind exactly such comments. The register makes
# honesty produce a tracked obligation instead:
#
#   LIMITATION(registre#<issue>): <the limited item, named on this line>
#
# backed by an issue in the PRIVATE dravr-ai/dravr-registre tracker (label
# `limitation` + a label naming the repo). Most dravr-* repos are PUBLIC —
# internal gaps and security residuals never go on the code repo's own tracker.
#
# Gates:
#   1. Deferral/confession prose ("for now, return", "not yet implemented",
#      "is the follow-up", "not yet wired", ...) in non-test sources — banned
#      unless the line carries a LIMITATION(registre#n): marker. Line-based
#      patterns can be defeated by a wrap mid-phrase; the authoring-time rule
#      in each repo's AGENTS.md is the primary enforcement, this is backstop.
#   2. Marker format — LIMITATION( without registre#<digits>: is malformed
#      (an unregistered exemption).
#   3. feature-phases.yaml (dark-launch ledger) — format-checked when present;
#      set LIMITATION_GATES_LEDGER=require to make the file itself mandatory.
#
# Usage: limitation-gates.sh <scan-dir>...
#   Scans *.rs/*.ts/*.tsx under the given dirs, excluding tests/benches/
#   examples/target/node_modules/dist and *_test.rs / *.test.* / *.spec.*.
# Exit: 0 clean, 1 violations found.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GATES_FAILED=false

gate_fail() {
    echo -e "${RED}❌ $1${NC}"
    GATES_FAILED=true
}

gate_pass() {
    echo -e "${GREEN}✅ $1${NC}"
}

# Keep only scan dirs that exist so callers can pass a superset.
SCAN_DIRS=()
for d in "$@"; do
    [ -d "$d" ] && SCAN_DIRS+=("$d")
done

if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
    echo -e "${YELLOW}limitation-gates: no scan directories exist, skipping${NC}"
    exit 0
fi

MARKER_RE='LIMITATION\(registre#[0-9]+\):'

# Shared rg scope: sources only, never test/bench/example/generated trees.
rg_scoped() {
    rg "$@" "${SCAN_DIRS[@]}" \
        -g '*.rs' -g '*.ts' -g '*.tsx' \
        -g '!**/tests/**' -g '!**/benches/**' -g '!**/examples/**' \
        -g '!*_test.rs' -g '!*.test.ts' -g '!*.test.tsx' -g '!*.spec.ts' -g '!*.spec.tsx' \
        -g '!**/target/**' -g '!**/node_modules/**' -g '!**/dist/**' \
        2>/dev/null
}

echo -e "${BLUE}==== Limitation Register Gates (shared) ====${NC}"

# ---------------------------------------------------------------------------
# Gate 1: deferral / confession prose without a registre marker
# ---------------------------------------------------------------------------
CONFESSION_PATTERNS='not yet implemented|in a real implementation|would be [a-z. ]*in production|would be database-backed|implement(ed)? later|for now, (return|store|trigger|set a default|we.?ll skip)|return empty[a-z. ]*for now|is the follow.?up|in a follow.?up (commit|change|pr)|not (yet )?threaded through|not yet wired'

CONFESSION_HITS=$(rg_scoped -i -n "$CONFESSION_PATTERNS" | rg -v "$MARKER_RE" || true)
CONFESSION_COUNT=$(printf '%s' "$CONFESSION_HITS" | grep -c . 2>/dev/null || true)

if [ "${CONFESSION_COUNT:-0}" -gt 0 ]; then
    echo -e "${RED}Unregistered deferral/confession prose (implement the real thing, or register with LIMITATION(registre#n): on the same line):${NC}"
    printf '%s\n' "$CONFESSION_HITS" | head -20
    gate_fail "$CONFESSION_COUNT unregistered deferral/confession comment(s)"
else
    gate_pass "No unregistered deferral/confession prose"
fi

# ---------------------------------------------------------------------------
# Gate 2: marker format
# ---------------------------------------------------------------------------
BAD_MARKERS=$(rg_scoped -n 'LIMITATION\(' | rg -v "$MARKER_RE" || true)
BAD_MARKER_COUNT=$(printf '%s' "$BAD_MARKERS" | grep -c . 2>/dev/null || true)

if [ "${BAD_MARKER_COUNT:-0}" -gt 0 ]; then
    echo -e "${RED}Malformed LIMITATION marker(s) — required form: LIMITATION(registre#<issue>):${NC}"
    printf '%s\n' "$BAD_MARKERS" | head -10
    gate_fail "$BAD_MARKER_COUNT malformed LIMITATION marker(s) (file the issue in dravr-ai/dravr-registre)"
else
    gate_pass "All LIMITATION markers reference a registre issue"
fi

# ---------------------------------------------------------------------------
# Gate 3: feature-phases.yaml (dark-launch ledger) format
# ---------------------------------------------------------------------------
PHASES_FILE="feature-phases.yaml"
if [ ! -f "$PHASES_FILE" ]; then
    if [ "${LIMITATION_GATES_LEDGER:-optional}" = "require" ]; then
        gate_fail "feature-phases.yaml missing — the dark-launch ledger must exist (an empty features: list is valid)"
    fi
else
    LEDGER_ENTRIES=$(grep -c '^  - name: ' "$PHASES_FILE" 2>/dev/null || true)
    LEDGER_OK=true
    for ledger_key in current advance_when review_by; do
        KEY_COUNT=$(grep -c "^    ${ledger_key}: " "$PHASES_FILE" 2>/dev/null || true)
        if [ "${KEY_COUNT:-0}" -ne "${LEDGER_ENTRIES:-0}" ]; then
            gate_fail "feature-phases.yaml: ${KEY_COUNT:-0} '${ledger_key}:' key(s) for ${LEDGER_ENTRIES:-0} entries — every entry needs name/current/advance_when/review_by"
            LEDGER_OK=false
        fi
    done
    BAD_REVIEW_DATES=$(grep '^    review_by: ' "$PHASES_FILE" 2>/dev/null | grep -Ev 'review_by: [0-9]{4}-[0-9]{2}-[0-9]{2}$' || true)
    if [ -n "$BAD_REVIEW_DATES" ]; then
        gate_fail "feature-phases.yaml: review_by must be YYYY-MM-DD — $BAD_REVIEW_DATES"
        LEDGER_OK=false
    fi
    if [ "$LEDGER_OK" = true ]; then
        gate_pass "Feature phase ledger well-formed (${LEDGER_ENTRIES:-0} dark-launched feature(s))"
    fi
fi

if [ "$GATES_FAILED" = true ]; then
    exit 1
fi
