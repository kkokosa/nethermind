#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-correctness-check.sh — Run targeted correctness tests for an optimization area
#
# Maps TARGET_ID prefix to the relevant test project(s) and runs them.
# Exit 0 = pass, non-zero = fail.
#
# Usage:
#   ./tools/perf-agents/run-correctness-check.sh <TARGET_ID> [WORKTREE_DIR]
#
# If WORKTREE_DIR is not provided, uses current directory.
# Writes result to ${LOOP_STATE_DIR}/correctness-result.json (if LOOP_STATE_DIR is set).
# =============================================================================

TARGET_ID="${1:?Usage: run-correctness-check.sh <TARGET_ID> [WORKTREE_DIR]}"
WORK_DIR="${2:-$(pwd)}"

# Extract area prefix (e.g., EVM from EVM-1, TRIE from TRIE-2)
AREA_PREFIX="${TARGET_ID%%-*}"

log() {
    echo "[correctness] $*"
}

# Map target area to test project paths (relative to src/Nethermind/)
declare -a TEST_PROJECTS=()

case "$AREA_PREFIX" in
    EVM)
        TEST_PROJECTS=(
            "src/Nethermind/Nethermind.Evm.Test/Nethermind.Evm.Test.csproj"
        )
        ;;
    TRIE)
        TEST_PROJECTS=(
            "src/Nethermind/Nethermind.Trie.Test/Nethermind.Trie.Test.csproj"
        )
        ;;
    STATE)
        TEST_PROJECTS=(
            "src/Nethermind/Nethermind.State.Test/Nethermind.State.Test.csproj"
        )
        ;;
    RLP)
        TEST_PROJECTS=(
            "src/Nethermind/Ethereum.Rlp.Test/Ethereum.Rlp.Test.csproj"
        )
        ;;
    DB)
        TEST_PROJECTS=(
            "src/Nethermind/Nethermind.Db.Test/Nethermind.Db.Test.csproj"
        )
        ;;
    NET|NETWORK)
        TEST_PROJECTS=(
            "src/Nethermind/Nethermind.Network.Test/Nethermind.Network.Test.csproj"
        )
        ;;
    *)
        log "WARNING: Unknown area prefix '$AREA_PREFIX', running core tests only"
        TEST_PROJECTS=(
            "src/Nethermind/Nethermind.Core.Test/Nethermind.Core.Test.csproj"
        )
        ;;
esac

cd "$WORK_DIR"

PASSED=0
FAILED=0
ERRORS=()
START_TIME=$(date +%s)

for proj in "${TEST_PROJECTS[@]}"; do
    if [ ! -f "$proj" ]; then
        log "WARNING: Test project not found: $proj (skipping)"
        continue
    fi

    log "Running: dotnet test $proj -c Release"
    if dotnet test "$proj" -c Release --no-restore --verbosity minimal 2>&1; then
        PASSED=$((PASSED + 1))
        log "PASS: $proj"
    else
        FAILED=$((FAILED + 1))
        ERRORS+=("$proj")
        log "FAIL: $proj"
    fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Write result JSON if LOOP_STATE_DIR is set
if [ -n "${LOOP_STATE_DIR:-}" ]; then
    RESULT_FILE="$WORK_DIR/$LOOP_STATE_DIR/correctness-result.json"
    mkdir -p "$(dirname "$RESULT_FILE")"

    ERRORS_JSON="[]"
    if [ ${#ERRORS[@]} -gt 0 ]; then
        ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin]))")
    fi

    cat > "$RESULT_FILE" << EOF
{
  "target_id": "$TARGET_ID",
  "area_prefix": "$AREA_PREFIX",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $((PASSED + FAILED)),
  "duration_s": $DURATION,
  "failed_projects": $ERRORS_JSON,
  "result": "$([ $FAILED -eq 0 ] && echo "pass" || echo "fail")",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    log "Result written to $RESULT_FILE"
fi

if [ $FAILED -gt 0 ]; then
    log "CORRECTNESS CHECK FAILED: $FAILED project(s) failed"
    for err in "${ERRORS[@]}"; do
        log "  - $err"
    done
    exit 1
fi

log "CORRECTNESS CHECK PASSED ($PASSED project(s), ${DURATION}s)"
exit 0
