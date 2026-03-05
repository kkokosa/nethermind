#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dummy-worker.sh — Simulated worker for testing the dashboard/tmux UI
#
# Mimics the real worker lifecycle (status files, log output, phase transitions,
# DB inserts for loop_runs/benchmark_results/comparisons) without running
# Claude, benchmarks, or touching git.
#
# Usage:
#   bash tools/perf-agents/dummy-worker.sh                     # random target
#   bash tools/perf-agents/dummy-worker.sh --target EVM-1      # specific target
#   bash tools/perf-agents/dummy-worker.sh --speed fast         # fast (2s phases)
#   bash tools/perf-agents/dummy-worker.sh --speed slow         # slow (30s phases)
#   bash tools/perf-agents/dummy-worker.sh --fail               # simulate failure
#   bash tools/perf-agents/dummy-worker.sh --pending            # stop at pending_decision
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"

# ── Defaults ─────────────────────────────────────────────────────────────────

TARGETS=("EVM-1" "EVM-2" "EVM-3" "TRIE-1" "TRIE-2" "STATE-1" "RLP-1" "DB-1" "BP-1")
TARGET=""
SPEED="normal"   # fast=2s, normal=8s, slow=30s per phase
FAIL=false
STOP_AT_PENDING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)          TARGET="$2"; shift 2 ;;
        --speed)           SPEED="$2"; shift 2 ;;
        --fail)            FAIL=true; shift ;;
        --pending)         STOP_AT_PENDING=true; shift ;;
        -h|--help)
            echo "Usage: dummy-worker.sh [--target ID] [--speed fast|normal|slow] [--fail] [--pending]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Pick target
if [ -z "$TARGET" ]; then
    TARGET="${TARGETS[$RANDOM % ${#TARGETS[@]}]}"
fi

# Derive area from target ID
TARGET_AREA=$(echo "$TARGET" | sed 's/-[0-9]*//' | tr '[:upper:]' '[:lower:]')

# Phase duration
case "$SPEED" in
    fast)   PHASE_SEC=2 ;;
    slow)   PHASE_SEC=30 ;;
    *)      PHASE_SEC=8 ;;
esac

# Generate IDs
LOOP_RUN_ID="LR-D$(date +%s)-$$"
BRANCH_NAME="perf-ai/dummy-${TARGET,,}-$(date +%s)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_ATTEMPTS=3

mkdir -p "$RUN_DIR/status" "$RUN_DIR/logs"
LOG_FILE="$RUN_DIR/logs/${LOOP_RUN_ID}-dummy.log"

# ── Fake benchmark data ──────────────────────────────────────────────────────

# Hypothesis texts per area
declare -A HYPOTHESES=(
    [evm]="EVM opcode dispatch uses virtual calls; replace with function pointer table to reduce branch mispredictions"
    [trie]="Patricia trie node decode allocates temporary byte arrays; use Span<byte> pooling to reduce GC pressure"
    [state]="WorldState.Get() does redundant hash computation on cache hit path; cache the hash alongside the value"
    [rlp]="RLP integer encoding allocates a new byte[] per call; use stackalloc for small values (<= 8 bytes)"
    [db]="RocksDB read path copies value bytes twice; use PinnableSlice to eliminate one copy"
    [bp]="Block validation recomputes transaction root even when already verified; skip on cache hit"
)

declare -A BENCH_CLASSES=(
    [evm]="EvmStackBenchmarks"
    [trie]="TrieNodeBenchmarks"
    [state]="WorldStateBenchmarks"
    [rlp]="RlpEncodeBenchmarks"
    [db]="RocksDbReadBenchmarks"
    [bp]="BlockProcessorBenchmarks"
)

declare -A BENCH_METHODS=(
    [evm]="PushPop DupSwap Uint256Add"
    [trie]="DecodeNode EncodePath GetNode"
    [state]="GetAccount SetStorage CommitTree"
    [rlp]="EncodeInt EncodeAddress EncodeTransaction"
    [db]="SequentialRead RandomRead MultiGet"
    [bp]="ProcessBlock ValidateBlock ExecuteTransactions"
)

HYPOTHESIS="${HYPOTHESES[$TARGET_AREA]:-Optimize hot path in $TARGET}"
BENCH_CLASS="${BENCH_CLASSES[$TARGET_AREA]:-GenericBenchmarks}"
METHODS="${BENCH_METHODS[$TARGET_AREA]:-Method1 Method2 Method3}"

START_EPOCH=$(date +%s)
PHASE_START_EPOCH="$START_EPOCH"
DUMMY_COST=0.00
TIMING_HISTORY='{"research":null,"attempts":[]}'
CURRENT_PHASE=""
CURRENT_DUMMY_ATTEMPT=0

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date -u +%H:%M:%S)] [$LOOP_RUN_ID] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

write_status() {
    local status="$1"
    local action="$2"
    local attempt="${3:-0}"
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed_total=$(( now_epoch - START_EPOCH ))
    local phase_elapsed=$(( now_epoch - PHASE_START_EPOCH ))

    # Track phase transition
    if [ -n "$CURRENT_PHASE" ] && [ "$CURRENT_PHASE" != "$status" ]; then
        local prev_dur=$(( now_epoch - PHASE_START_EPOCH ))
        local phase_cost
        phase_cost=$(python3 -c "import random; print(f'{random.uniform(0.1, 0.8):.2f}')")
        DUMMY_COST=$(python3 -c "print(f'{$DUMMY_COST + $phase_cost:.2f}')")

        TIMING_HISTORY=$(python3 -c "
import json
h = json.loads('''$TIMING_HISTORY''')
phase = '$CURRENT_PHASE'
attempt = $CURRENT_DUMMY_ATTEMPT
dur = $prev_dur
cost = $phase_cost
if phase == 'research':
    h['research'] = {'duration_s': dur, 'cost': round(cost, 4)}
elif attempt > 0:
    while len(h['attempts']) < attempt:
        h['attempts'].append({'attempt': len(h['attempts'])+1, 'phases': {}, 'cost': 0})
    a = h['attempts'][attempt-1]
    a['phases'][phase] = dur
    a['cost'] = round(a['cost'] + cost, 4)
print(json.dumps(h))
")
        PHASE_START_EPOCH="$now_epoch"
        phase_elapsed=0
    fi
    CURRENT_PHASE="$status"
    CURRENT_DUMMY_ATTEMPT="$attempt"

    cat > "$RUN_DIR/status/${LOOP_RUN_ID}.json" << EOF
{
  "id": "${LOOP_RUN_ID}",
  "targetId": "${TARGET}",
  "status": "${status}",
  "attempt": ${attempt},
  "maxAttempts": ${MAX_ATTEMPTS},
  "currentAction": "${action}",
  "branch": "${BRANCH_NAME}",
  "worktree": "/tmp/dummy-worktree",
  "startedAt": "${STARTED_AT}",
  "phaseStartedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "elapsedTotal": ${elapsed_total},
  "phaseElapsed": ${phase_elapsed},
  "costUsd": ${DUMMY_COST},
  "timingHistory": ${TIMING_HISTORY},
  "pid": $$
}
EOF
}

db_exec() {
    # Retry with busy timeout to handle concurrent workers
    local attempts=0
    while [ $attempts -lt 5 ]; do
        if sqlite3 "$DB_PATH" "PRAGMA busy_timeout=5000; $1" 2>/dev/null; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    log "WARNING: DB exec failed after 5 retries"
    return 1
}

db_query() {
    sqlite3 "$DB_PATH" "PRAGMA busy_timeout=5000; $1" 2>/dev/null
}

db_update_status() {
    local status="$1"
    local extra="${2:-}"
    db_exec "UPDATE loop_runs SET status='$status', updated_at=datetime('now') $extra WHERE id='$LOOP_RUN_ID'"
}

cleanup() {
    log "Dummy worker cleanup"
    rm -f "$RUN_DIR/status/${LOOP_RUN_ID}.json"
}
trap cleanup EXIT

phase() {
    local name="$1"
    local action="$2"
    local attempt="${3:-0}"
    log "Phase: $name — $action"
    write_status "$name" "$action" "$attempt"
    # Add 0-80% random jitter to phase duration
    local jitter
    jitter=$(python3 -c "import random; print(f'{$PHASE_SEC * random.uniform(0.2, 1.8):.1f}')")
    sleep "$jitter"
}

# Random float in range: rand_float MIN MAX (2 decimal places)
rand_float() {
    local min="$1" max="$2"
    python3 -c "import random; print(f'{random.uniform($min,$max):.2f}')"
}

# ── Insert fake benchmark results + comparisons ─────────────────────────────

insert_benchmark_data() {
    local improvement="$1"  # true or false

    for method in $METHODS; do
        local full_name="Nethermind.${BENCH_CLASS}.${method}"
        local baseline_ns=$(rand_float 50 5000)
        local baseline_alloc=$(( RANDOM % 500 + 50 ))

        local delta_pct
        if $improvement; then
            delta_pct=$(rand_float -18 -5)
        else
            delta_pct=$(rand_float -3 3)
        fi

        local candidate_ns
        candidate_ns=$(python3 -c "print(f'{$baseline_ns * (1 + $delta_pct/100):.2f}')")
        local candidate_alloc
        if $improvement; then
            candidate_alloc=$(python3 -c "import random; print(max(0, int($baseline_alloc * random.uniform(0.5, 0.9))))")
        else
            candidate_alloc="$baseline_alloc"
        fi
        local delta_alloc_pct
        delta_alloc_pct=$(python3 -c "print(f'{($candidate_alloc - $baseline_alloc) / max($baseline_alloc, 1) * 100:.1f}')")

        local p_value
        if $improvement; then
            p_value=$(rand_float 0.001 0.03)
        else
            p_value=$(rand_float 0.06 0.8)
        fi

        local is_significant=0
        if $improvement; then is_significant=1; fi

        local stddev_ns
        stddev_ns=$(python3 -c "print(f'{$baseline_ns * 0.03:.2f}')")

        db_exec "
            INSERT OR REPLACE INTO benchmark_results
                (loop_run_id, side, benchmark_class, benchmark_method, full_name,
                 mean_ns, median_ns, stddev_ns, allocated_bytes, iterations)
            VALUES
                ('$LOOP_RUN_ID', 'baseline', '$BENCH_CLASS', '$method', '$full_name',
                 $baseline_ns, $baseline_ns, $stddev_ns, $baseline_alloc, 1000),
                ('$LOOP_RUN_ID', 'candidate', '$BENCH_CLASS', '$method', '$full_name',
                 $candidate_ns, $candidate_ns, $stddev_ns, $candidate_alloc, 1000);

            INSERT OR REPLACE INTO comparisons
                (loop_run_id, full_name, delta_mean_pct, delta_alloc_pct,
                 p_value, is_significant, effect_size,
                 baseline_mean_ns, candidate_mean_ns,
                 baseline_alloc, candidate_alloc)
            VALUES
                ('$LOOP_RUN_ID', '$full_name', $delta_pct, $delta_alloc_pct,
                 $p_value, $is_significant, 0.8,
                 $baseline_ns, $candidate_ns,
                 $baseline_alloc, $candidate_alloc);
        " || log "WARNING: failed to insert benchmark data for $method"
    done
}

# ── Rename tmux session ─────────────────────────────────────────────────────

if [ -n "${TMUX:-}" ]; then
    tmux rename-session "W:${TARGET}"
fi

# ── Simulate lifecycle ───────────────────────────────────────────────────────

log "=== DUMMY WORKER START ==="
log "Target: $TARGET | Area: $TARGET_AREA | Speed: $SPEED | Fail: $FAIL | Pending: $STOP_AT_PENDING"

# Phase 0: Claim — insert loop_run into DB
phase "claiming" "Claiming target $TARGET..."

DIFFICULTY=$(python3 -c "import random; print(random.choice(['S','M','L']))")
IMPACT=$(python3 -c "import random; print(random.choice(['low','med','high']))")
COST=$(rand_float 0.5 8.0)
TOKENS=$(( RANDOM % 500000 + 50000 ))

db_exec "
    INSERT INTO loop_runs
        (id, target_id, target_area, status, hypothesis, difficulty, expected_impact,
         branch, agent_type, cost_usd, total_tokens)
    VALUES
        ('$LOOP_RUN_ID', '$TARGET', '$TARGET_AREA', 'research',
         '$HYPOTHESIS', '$DIFFICULTY', '$IMPACT',
         '$BRANCH_NAME', 'claude-code-dummy', $COST, $TOKENS);
" || log "WARNING: failed to insert loop_run"

log "Claimed: $TARGET -> $LOOP_RUN_ID"

# Phase 0b: Worktree
phase "setup" "Creating worktree..."

# Phase 1-2: Research
db_update_status "research"
phase "research" "Running Claude Code for research..."
sleep "$PHASE_SEC"
phase "research" "Analyzing hotspots in ${TARGET}..."
sleep "$PHASE_SEC"
phase "research" "Writing hypothesis..."
log "Research complete — hypothesis: $HYPOTHESIS"

# Phase 3-5: Implement + Benchmark loop
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    log "=== Attempt $attempt/$MAX_ATTEMPTS ==="

    db_update_status "implementing" ", iterations=$attempt"
    phase "implementing" "Attempt $attempt — implementing optimization..." "$attempt"
    sleep "$PHASE_SEC"
    phase "implementing" "Attempt $attempt — writing benchmark..." "$attempt"
    sleep "$PHASE_SEC"

    db_update_status "benchmarking"
    phase "benchmarking" "Attempt $attempt — running BenchmarkDotNet..." "$attempt"
    sleep "$PHASE_SEC"

    if $FAIL; then
        # Insert mediocre benchmark data
        log "Inserting neutral benchmark results..."
        insert_benchmark_data false
        phase "benchmarking" "Attempt $attempt — comparing results..." "$attempt"

        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
            log "Attempt $attempt: insufficient improvement (-1.2%). Retrying."
            db_update_status "iterating" ", approach='Attempt $attempt: delta=-1.2%'"
            phase "iterating" "Preparing retry (attempt $((attempt+1)))" "$attempt"
        else
            log "All attempts exhausted."
            db_update_status "discarded" ", verdict='inconclusive', verdict_notes='Exhausted $MAX_ATTEMPTS attempts (dummy)'"
            phase "error" "Exhausted $MAX_ATTEMPTS attempts" "$attempt"
            log "=== DUMMY WORKER FINISHED (inconclusive) ==="
            exit 0
        fi
    else
        # Insert successful benchmark data
        log "Inserting improved benchmark results..."
        insert_benchmark_data true
        phase "benchmarking" "Attempt $attempt — comparing results..." "$attempt"

        BEST_DELTA=$(db_query "SELECT MIN(delta_mean_pct) FROM comparisons WHERE loop_run_id='$LOOP_RUN_ID' AND is_significant=1" || echo "-12.3")

        log "IMPROVEMENT: ${BEST_DELTA}% — requesting human decision"
        db_update_status "pending_decision"
        phase "pending_decision" "Waiting for human review (${BEST_DELTA}% improvement)" "$attempt"

        # Wait for human verdict from the dashboard
        log "Awaiting human verdict at http://localhost:4040 ..."
        while true; do
            VERDICT=$(db_query "SELECT verdict FROM loop_runs WHERE id='$LOOP_RUN_ID'" || echo "")
            if [ -n "$VERDICT" ]; then
                log "Verdict received: $VERDICT"
                log "=== DUMMY WORKER FINISHED ($VERDICT) ==="
                exit 0
            fi
            write_status "pending_decision" \
                "Waiting for human review (${BEST_DELTA}% improvement)" "$attempt"
            sleep 5
        done
    fi
done

log "=== DUMMY WORKER FINISHED ==="
