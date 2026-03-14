#!/usr/bin/env bash
set -uo pipefail

# Language-agnostic test suite for the lrs binary.
# Usage: ./run-tests.sh <path-to-lrs-binary>

LRS="${1:?Usage: $0 <path-to-lrs-binary>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA="$SCRIPT_DIR/data"
SHARED_DATA="$REPO/haskell/test-data"

PASSED=0
FAILED=0

fail() {
    echo "  FAIL: $1"
    FAILED=$((FAILED + 1))
}

pass() {
    echo "  PASS: $1"
    PASSED=$((PASSED + 1))
}

check_output() {
    local desc="$1"
    local pattern="$2"
    if echo "$OUTPUT" | grep -qE "$pattern"; then
        pass "$desc"
    else
        fail "$desc"
        echo "    Expected pattern: $pattern"
        echo "    Got output:"
        echo "$OUTPUT" | sed 's/^/    /'
    fi
}

check_no_output() {
    local desc="$1"
    local pattern="$2"
    if echo "$OUTPUT" | grep -qE "$pattern"; then
        fail "$desc"
        echo "    Should NOT match pattern: $pattern"
        echo "    Got output:"
        echo "$OUTPUT" | sed 's/^/    /'
    else
        pass "$desc"
    fi
}

check_line_count() {
    local desc="$1"
    local min_count="$2"
    # Count result lines (lines starting with a number)
    local count
    count=$(echo "$OUTPUT" | grep -cE '^\s*[0-9]' || true)
    if [ "$count" -ge "$min_count" ]; then
        pass "$desc"
    else
        fail "$desc (got $count results, expected >= $min_count)"
        echo "    Got output:"
        echo "$OUTPUT" | sed 's/^/    /'
    fi
}

# ============================================================
echo "=== Test 1: Single file, long repeated substring ==="
OUTPUT=$("$LRS" "$SHARED_DATA/single.txt" -n 5 2>&1)
check_output "top result is DEADBEEF CAFEBABE" '1 +29 +2 +.*DEADBEEF CAFEBABE'
check_line_count "produces multiple results" 2

# ============================================================
echo "=== Test 2: Short repeated substrings only ==="
OUTPUT=$("$LRS" "$SHARED_DATA/short.txt" -n 10 2>&1)
check_output "contains 'x '" '"x "'
check_output "contains 'y '" '"y "'

# ============================================================
echo "=== Test 3: Multi-file directory ==="
OUTPUT=$("$LRS" "$SHARED_DATA/project/src/alpha.txt" \
                "$SHARED_DATA/project/src/beta.txt" \
                "$SHARED_DATA/project/lib/gamma.txt" \
                "$SHARED_DATA/project/lib/delta.txt" -n 3 2>&1)
check_output "top result is the riverbank line (len 67)" '1 +67 +2'

# ============================================================
echo "=== Test 4: Multiple independent repeated substrings (single file) ==="
OUTPUT=$("$LRS" "$DATA/multi-repeat.txt" -n 10 2>&1)
check_output "finds alpha line" 'quick brown fox'
check_output "finds gamma line" 'pack my box'
check_output "finds epsilon line" 'hello world'
check_line_count "at least 3 distinct results" 3

# ============================================================
echo "=== Test 5: Multiple independent repeated substrings (multi-file) ==="
OUTPUT=$("$LRS" "$DATA/dir/one.txt" "$DATA/dir/two.txt" \
                "$DATA/dir/three.txt" "$DATA/dir/four.txt" -n 10 2>&1)
check_output "finds alpha line across files" 'quick brown fox'
check_output "finds gamma line across files" 'pack my box'
check_output "finds epsilon line across files" 'hello world'
check_line_count "at least 3 distinct results from multi-file" 3

# ============================================================
echo "=== Test 6: --min-length filtering ==="
OUTPUT=$("$LRS" "$DATA/multi-repeat.txt" --min-length 50 -n 10 2>&1)
check_output "alpha line passes min-length 50" 'quick brown fox'
# gamma line is 48 chars with prefix+newline, should be filtered
check_no_output "gamma line filtered by --min-length 50" 'pack my box'
check_no_output "epsilon line filtered by --min-length 50" 'hello world'

# ============================================================
echo "=== Test 7: Short pattern with higher count survives dedup ==="
OUTPUT=$("$LRS" "$DATA/dedup-count.txt" -n 10 2>&1)
# "alpha" appears in 7 lines but the long block only repeats 2x.
# "word alpha appears" (count 5) must NOT be suppressed by the long block (count 2).
check_output "long block found" 'long block.*alpha beta gamma'
check_output "short high-count pattern survives dedup" 'word alpha appears'
check_line_count "at least 2 distinct results" 2

# ============================================================
echo "=== Test 8: --collapse-whitespace normalizes whitespace ==="
OUTPUT=$("$LRS" "$DATA/whitespace.txt" --collapse-whitespace -n 5 2>&1)
check_output "finds 'hello world foo bar' after collapsing" 'hello world foo bar'
# Without collapse, "hello   world   foo   bar" != "hello world foo bar"
# With collapse, they become identical, forming a repeated substring

# ============================================================
echo "=== Test 9: -n limits results ==="
OUTPUT=$("$LRS" "$DATA/multi-repeat.txt" -n 1 2>&1)
check_line_count "exactly 1 result with -n 1" 1
# Should not have more than 1
count=$(echo "$OUTPUT" | grep -cE '^\s*[0-9]' || true)
if [ "$count" -le 1 ]; then
    pass "-n 1 gives at most 1 result"
else
    fail "-n 1 gives at most 1 result (got $count)"
fi

# ============================================================
echo "=== Test 9: Overlapping patterns not incorrectly dominated ==="
# A shorter repeated pattern that starts within a longer pattern's text
# region but extends past it is NOT a substring of the longer pattern.
# It must survive dedup as an independent result.
OUTPUT=$("$LRS" "$DATA/overlap.txt" -n 5 2>&1)
check_output "finds long pattern" '68 +2 +.*AAAAAAAAAAAAAAA'
# The 46-char pattern "CCCCCCCCC_..._FFFFFFFFF" overlaps with the 68-char
# pattern in text position but extends past it. It must not be suppressed.
check_output "overlapping shorter pattern survives" '4[56] +2 +.*CCCCCCCCC.*FFFFFFFFF'
# "CCCCCCCCC_DDDDDDDDDDDDDDD_EEEEEEEEE_" appears 3 times (higher count
# than the 68-char pattern) and must also survive as an independent result.
check_output "higher-count overlap pattern survives" '3[0-9] +3 +.*CCCCCCCCC.*EEEEEEEEE'

# ============================================================
echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
