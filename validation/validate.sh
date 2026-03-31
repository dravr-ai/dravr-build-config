#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Universal architectural validation for all dravr-* Rust projects
# ABOUTME: Reads patterns.toml baseline + optional local overrides

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PATTERNS_FILE="$SCRIPT_DIR/patterns.toml"
LOCAL_PATTERNS_FILE="$PROJECT_ROOT/validation-patterns.local.toml"

VALIDATION_FAILED=false

fail_validation() {
    echo -e "${RED}❌ $1${NC}"
    VALIDATION_FAILED=true
}

pass_validation() {
    echo -e "${GREEN}✅ $1${NC}"
}

warn_validation() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Determine scan paths
SRC_PATHS=""
TEST_PATHS=""
if [ -d "$PROJECT_ROOT/crates" ]; then
    SRC_PATHS="$PROJECT_ROOT/crates/*/src/"
    TEST_PATHS="$PROJECT_ROOT/crates/*/tests/"
fi
if [ -d "$PROJECT_ROOT/src" ]; then
    SRC_PATHS="$SRC_PATHS $PROJECT_ROOT/src/"
fi
if [ -d "$PROJECT_ROOT/tests" ]; then
    TEST_PATHS="$TEST_PATHS $PROJECT_ROOT/tests/"
fi

# Verify we have something to scan
if [ -z "$SRC_PATHS" ]; then
    echo -e "${YELLOW}No Rust source directories found, skipping${NC}"
    exit 0
fi

echo -e "${BLUE}==== Dravr Architectural Validation ====${NC}"
echo "Project: $PROJECT_ROOT"
echo "Sources: $SRC_PATHS"

cd "$PROJECT_ROOT"

# Parse patterns from TOML (simple grep-based, no Python dependency)
get_pattern() {
    local key="$1"
    grep "^${key} = " "$PATTERNS_FILE" 2>/dev/null | sed 's/.*= "//' | sed 's/"$//' || echo ""
}

# ============================================================================
# FAST-FAIL: Backup files
# ============================================================================
echo ""
echo -e "${BLUE}Checking for backup files...${NC}"
BACKUP_FILES=$(find $SRC_PATHS -name "*.backup" -o -name "*.bak" -o -name "*~" 2>/dev/null | head -5)
if [ -n "$BACKUP_FILES" ]; then
    fail_validation "Backup files found — remove before committing"
    echo "$BACKUP_FILES"
else
    pass_validation "No backup files"
fi

# ============================================================================
# Placeholder detection
# ============================================================================
echo -e "${BLUE}Checking for placeholder implementations...${NC}"
PLACEHOLDER_PATTERNS="stub implementation|stub for now|mock implementation|placeholder implementation|will be implemented|to be implemented|not yet implemented|In future versions|Implement the code|return mock data"
# Exclude comments (/// and //) to avoid matching documentation that describes placeholders
PLACEHOLDERS=$(rg -i "$PLACEHOLDER_PATTERNS" $SRC_PATHS 2>/dev/null | rg -v "^\s*///|^\s*//" | wc -l | tr -d ' ')
PLACEHOLDERS=${PLACEHOLDERS:-0}
if [ "$PLACEHOLDERS" -gt 0 ]; then
    fail_validation "Found $PLACEHOLDERS placeholder implementations"
    rg -i "$PLACEHOLDER_PATTERNS" $SRC_PATHS -n 2>/dev/null | rg -v "^\s*///|^\s*//" | head -5
else
    pass_validation "No placeholder implementations"
fi

# ============================================================================
# Error handling: anyhow forbidden
# ============================================================================
echo -e "${BLUE}Checking for forbidden anyhow usage...${NC}"
ANYHOW_MACRO=$(rg "\\banyhow!\\(|anyhow::anyhow!\\(" $SRC_PATHS --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
ANYHOW_IMPORTS=$(rg "use anyhow::" $SRC_PATHS --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
ANYHOW_TOTAL=$((ANYHOW_MACRO + ANYHOW_IMPORTS))
if [ "$ANYHOW_TOTAL" -gt 0 ]; then
    fail_validation "Found $ANYHOW_TOTAL anyhow usages (use structured error types)"
    rg "\\banyhow!\\(|use anyhow::" $SRC_PATHS -n 2>/dev/null | head -5
else
    pass_validation "No anyhow usage"
fi

# ============================================================================
# Problematic unwraps/expects/panics
# ============================================================================
echo -e "${BLUE}Checking for problematic error handling...${NC}"
UNWRAPS=$(rg "\.unwrap\(\)" $SRC_PATHS 2>/dev/null | rg -v "// Safe|hardcoded.*valid|static.*data" | wc -l | tr -d ' ')
EXPECTS=$(rg "\.expect\(" $SRC_PATHS 2>/dev/null | rg -v "// Safe" | wc -l | tr -d ' ')
PANICS=$(rg "panic!\(" $SRC_PATHS --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
if [ "${UNWRAPS:-0}" -gt 0 ]; then
    fail_validation "Found $UNWRAPS problematic .unwrap() calls"
fi
if [ "${EXPECTS:-0}" -gt 0 ]; then
    fail_validation "Found $EXPECTS problematic .expect() calls"
fi
if [ "${PANICS:-0}" -gt 0 ]; then
    fail_validation "Found $PANICS panic!() calls in production code"
fi
if [ "${UNWRAPS:-0}" -eq 0 ] && [ "${EXPECTS:-0}" -eq 0 ] && [ "${PANICS:-0}" -eq 0 ]; then
    pass_validation "No problematic error handling"
fi

# ============================================================================
# TODOs/FIXMEs
# ============================================================================
echo -e "${BLUE}Checking for incomplete code markers...${NC}"
TODOS=$(rg "TODO|FIXME|XXX" $SRC_PATHS -g "!*.json" -g "!*.md" --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
TODOS_TESTS=$(rg "TODO|FIXME|XXX" $TEST_PATHS -g "!*.json" -g "!*.md" --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
TODOS_TOTAL=$((TODOS + TODOS_TESTS))
if [ "$TODOS_TOTAL" -gt 0 ]; then
    fail_validation "Found $TODOS_TOTAL TODO/FIXME/XXX markers (src:$TODOS tests:$TODOS_TESTS)"
else
    pass_validation "No incomplete code markers"
fi

# ============================================================================
# Production mocks
# ============================================================================
echo -e "${BLUE}Checking for production mock code...${NC}"
MOCKS=$(rg "mock_|get_mock|return.*mock|demo purposes|stub implementation|mock implementation" $SRC_PATHS -g "!*/bin/*" -g "!*/tests/*" 2>/dev/null | rg -v "// |/// |//!" | wc -l | tr -d ' ')
if [ "${MOCKS:-0}" -gt 0 ]; then
    fail_validation "Found $MOCKS mock/stub patterns in production code"
else
    pass_validation "No production mocks"
fi

# ============================================================================
# Underscore-prefixed names
# ============================================================================
echo -e "${BLUE}Checking for underscore-prefixed names...${NC}"
UNDERSCORES=$(rg "fn _[a-zA-Z]|let _[a-zA-Z]|struct _[a-zA-Z]|enum _[a-zA-Z]" $SRC_PATHS -g "!*/bin/*" --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
if [ "$UNDERSCORES" -gt 0 ]; then
    fail_validation "Found $UNDERSCORES underscore-prefixed names (remove variable, don't hide it)"
    rg "fn _[a-zA-Z]|let _[a-zA-Z]|struct _[a-zA-Z]|enum _[a-zA-Z]" $SRC_PATHS -g "!*/bin/*" -n 2>/dev/null | head -5
else
    pass_validation "No underscore-prefixed names"
fi

# ============================================================================
# Forbidden clippy allows
# ============================================================================
echo -e "${BLUE}Checking for unauthorized #[allow(clippy::...)]...${NC}"
ALLOWED_CLIPPY="cast_possible_truncation|cast_sign_loss|cast_precision_loss|cast_possible_wrap|struct_excessive_bools|too_many_lines|let_unit_value|option_if_let_else|cognitive_complexity|bool_to_int_with_if|type_complexity|too_many_arguments|use_self"

# Load local extensions if present
if [ -f "$LOCAL_PATTERNS_FILE" ]; then
    LOCAL_ALLOWED=$(grep "^allowed_extra" "$LOCAL_PATTERNS_FILE" 2>/dev/null | sed 's/.*= "//' | sed 's/"$//' || echo "")
    if [ -n "$LOCAL_ALLOWED" ]; then
        ALLOWED_CLIPPY="$ALLOWED_CLIPPY|$LOCAL_ALLOWED"
    fi
fi

CLIPPY_ALLOWS=$(rg "#\[allow\(clippy::" $SRC_PATHS -g "!*/bin/*" 2>/dev/null | grep -v -E "$ALLOWED_CLIPPY" | wc -l | tr -d ' ')
if [ "${CLIPPY_ALLOWS:-0}" -gt 0 ]; then
    fail_validation "Found $CLIPPY_ALLOWS unauthorized #[allow(clippy::)] attributes"
    rg "#\[allow\(clippy::" $SRC_PATHS -g "!*/bin/*" -n 2>/dev/null | grep -v -E "$ALLOWED_CLIPPY" | head -5
else
    pass_validation "No unauthorized clippy allows"
fi

# ============================================================================
# Dead code annotations
# ============================================================================
echo -e "${BLUE}Checking for dead code hiding...${NC}"
DEAD_CODE=$(rg "#\[allow\(dead_code\)\]" $SRC_PATHS --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
if [ "$DEAD_CODE" -gt 0 ]; then
    fail_validation "Found $DEAD_CODE #[allow(dead_code)] — remove the dead code instead"
else
    pass_validation "No dead code annotations"
fi

# ============================================================================
# #[cfg(test)] in src (tests belong in tests/)
# ============================================================================
echo -e "${BLUE}Checking for test modules in src...${NC}"
CFG_TEST=$(rg "#\[cfg\(test\)\]" $SRC_PATHS --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
if [ "$CFG_TEST" -gt 0 ]; then
    fail_validation "Found $CFG_TEST #[cfg(test)] in src/ — tests go in tests/ directory"
else
    pass_validation "No test modules in src"
fi

# ============================================================================
# Temporary solutions
# ============================================================================
echo -e "${BLUE}Checking for temporary solutions...${NC}"
TEMP=$(rg "\\bhack\\b|\\bworkaround\\b|\\bquick.*fix\\b|future.*implementation|temporary.*solution|temp.*fix" $SRC_PATHS --count-matches 2>/dev/null | cut -d: -f2 | awk '{sum+=$1} END {print sum+0}')
if [ "${TEMP:-0}" -gt 0 ]; then
    fail_validation "Found $TEMP temporary solution markers"
else
    pass_validation "No temporary solutions"
fi

# ============================================================================
# Empty source modules
# ============================================================================
echo -e "${BLUE}Checking for empty source modules...${NC}"
EMPTY_MODULES=0
for rs_file in $(find $SRC_PATHS -name "*.rs" -not -path "*/tests/*" -not -path "*/bin/*" 2>/dev/null); do
    DECL_COUNT=$(rg "^(pub )?(pub\(crate\) )?(async )?(fn |struct |enum |impl |const |static |type |trait |macro|mod |use )" "$rs_file" --count 2>/dev/null || echo 0)
    if [ "$DECL_COUNT" -eq 0 ]; then
        EMPTY_MODULES=$((EMPTY_MODULES + 1))
        echo "  Empty: $rs_file"
    fi
done
if [ "$EMPTY_MODULES" -gt 0 ]; then
    fail_validation "Found $EMPTY_MODULES empty source modules"
else
    pass_validation "No empty source modules"
fi

# ============================================================================
# Test integrity: ignored tests
# ============================================================================
echo -e "${BLUE}Checking test integrity...${NC}"
if [ -n "$TEST_PATHS" ]; then
    IGNORED_TESTS=$(rg '#\[ignore' $TEST_PATHS --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
    # Check allowlist
    ALLOWED_IGNORED=0
    if [ -f "$PROJECT_ROOT/ignored-tests-allowlist.toml" ]; then
        ALLOWLIST_FILES=$(python3 -c "
import tomllib
with open('$PROJECT_ROOT/ignored-tests-allowlist.toml', 'rb') as f:
    config = tomllib.load(f)
print(' '.join(config.get('files', [])))
" 2>/dev/null || echo "")
        if [ -n "$ALLOWLIST_FILES" ]; then
            for f in $ALLOWLIST_FILES; do
                COUNT=$(rg '#\[ignore' "$f" -c 2>/dev/null || echo 0)
                ALLOWED_IGNORED=$((ALLOWED_IGNORED + COUNT))
            done
        fi
    fi
    UNAUTHORIZED=$((IGNORED_TESTS - ALLOWED_IGNORED))
    if [ "$UNAUTHORIZED" -gt 0 ]; then
        fail_validation "Found $UNAUTHORIZED unauthorized ignored tests (total: $IGNORED_TESTS, allowed: $ALLOWED_IGNORED)"
    else
        if [ "$IGNORED_TESTS" -gt 0 ]; then
            pass_validation "All $IGNORED_TESTS ignored tests are in allowlist"
        else
            pass_validation "No ignored tests"
        fi
    fi
fi

# ============================================================================
# CI continue-on-error
# ============================================================================
if [ -d "$PROJECT_ROOT/.github/workflows" ]; then
    echo -e "${BLUE}Checking CI integrity...${NC}"
    # Count continue-on-error, excluding comments and excluded workflows
    COE_EXCLUDES=""
    if [ -f "$LOCAL_PATTERNS_FILE" ]; then
        COE_EXCLUDES=$(grep "exclude_workflows" "$LOCAL_PATTERNS_FILE" 2>/dev/null | sed 's/.*\[//' | sed 's/\]//' | tr -d '"' | tr ',' '\n' | sed 's/^ //' || echo "")
    fi
    COE_RESULT=$(rg "continue-on-error: true" "$PROJECT_ROOT/.github/workflows/" 2>/dev/null | grep -v "#.*continue-on-error" || true)
    for excl in $COE_EXCLUDES; do
        COE_RESULT=$(echo "$COE_RESULT" | grep -v "$excl" || true)
    done
    COE=$(echo "$COE_RESULT" | grep -c "continue-on-error" || echo 0)
    if [ "$COE" -gt 0 ]; then
        fail_validation "Found $COE continue-on-error: true in CI workflows"
    else
        pass_validation "No continue-on-error in CI"
    fi
fi

# ============================================================================
# JS/TS test integrity (if frontend exists)
# ============================================================================
FRONTEND_PATHS=""
[ -d "$PROJECT_ROOT/frontend" ] && FRONTEND_PATHS="$FRONTEND_PATHS $PROJECT_ROOT/frontend/"
[ -d "$PROJECT_ROOT/sdk" ] && FRONTEND_PATHS="$FRONTEND_PATHS $PROJECT_ROOT/sdk/"
[ -d "$PROJECT_ROOT/frontend-mobile" ] && FRONTEND_PATHS="$FRONTEND_PATHS $PROJECT_ROOT/frontend-mobile/"

if [ -n "$FRONTEND_PATHS" ]; then
    echo -e "${BLUE}Checking JS/TS test integrity...${NC}"
    JS_SKIPS=$(rg "\\.skip\\(|xit\\(|xdescribe\\(|test\\.skip\\(" $FRONTEND_PATHS -g "*.test.*" -g "*.spec.*" --count 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
    if [ "${JS_SKIPS:-0}" -gt 0 ]; then
        fail_validation "Found $JS_SKIPS skipped JS/TS tests"
    else
        pass_validation "No skipped JS/TS tests"
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${BLUE}==== Architectural Validation Summary ====${NC}"
if [ "$VALIDATION_FAILED" = true ]; then
    echo -e "${RED}❌ Architectural validation FAILED${NC}"
    echo -e "${RED}Fix critical issues above before deployment${NC}"
    exit 1
else
    echo -e "${GREEN}✅ All architectural validations passed${NC}"
fi
