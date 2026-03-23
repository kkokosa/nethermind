#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# worker.sh v2 — Autonomous optimization loop for one target
#
# Each worker:
#   1. Claims a target atomically (or receives one via --target)
#   2. Creates a git worktree for isolation
#   3. Runs research (Claude Code session 1)
#   4. Runs implement+benchmark in a loop (Claude Code session 2, up to 3 attempts)
#   5. On success: sets pending_decision, waits for human verdict
#   6. On verdict: cleans up worktree
#
# Usage:
#   ./tools/perf-agents/worker.sh                   # claim best target
#   ./tools/perf-agents/worker.sh --target EVM-1    # force specific target
#   ./tools/perf-agents/worker.sh --exclude EVM-1,TRIE-2
#   ./tools/perf-agents/worker.sh --dry-run         # skip Claude Code + benchmarks, test pipeline
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
PROMPTS_DIR="$SCRIPT_DIR/PROMPTS"
RUN_DIR="$SCRIPT_DIR/run"
WORKTREE_ROOT="$REPO_ROOT/.worktrees"
BENCHMARK_LOCK="$RUN_DIR/benchmark.lock"

PYTHON="python3"
if ! command -v "$PYTHON" &>/dev/null; then
    echo "ERROR: python3 not found. Install Python 3 and ensure python3 is on PATH."
    exit 1
fi

# Export env vars for MCP server and settings templates
export PERF_DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
export PERF_REPO_ROOT="$REPO_ROOT"

MAX_ATTEMPTS=3
MAX_TURNS=50
DECISION_POLL_INTERVAL=30
DRY_RUN=false

# ─── Parse args ──────────────────────────────────────────────────────────────

CLAIM_ARGS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   CLAIM_ARGS="$CLAIM_ARGS --target $2"; shift 2 ;;
        --exclude)  CLAIM_ARGS="$CLAIM_ARGS --exclude $2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────

LOOP_RUN_ID=""  # set after claim
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PHASE_STARTED_AT="$STARTED_AT"
TOTAL_COST=0.00
LAST_SESSION_COST=0.00
# Timing history: {"research": {"duration_s": N, "cost": N}, "attempts": [{attempt, phases: {}, cost}]}
TIMING_HISTORY='{"research":null,"attempts":[]}'

log() {
    echo "[$(date -u +%H:%M:%S)] [${LOOP_RUN_ID:-INIT}] $*"
}

start_phase() {
    # Record phase start time; close previous phase in timing history
    local new_phase="$1"
    local now
    now=$(date +%s)
    if [ -n "${CURRENT_PHASE:-}" ] && [ -n "${PHASE_START_EPOCH:-}" ]; then
        local elapsed=$(( now - PHASE_START_EPOCH ))
        TIMING_HISTORY=$("$PYTHON" -c "
import json
h = json.loads('''$TIMING_HISTORY''')
phase = '$CURRENT_PHASE'
attempt = ${CURRENT_ATTEMPT:-0}
dur = $elapsed
cost = $LAST_SESSION_COST

if phase == 'research':
    h['research'] = {'duration_s': dur, 'cost': round(cost, 4)}
elif attempt > 0:
    # Find or create attempt entry
    while len(h['attempts']) < attempt:
        h['attempts'].append({'attempt': len(h['attempts'])+1, 'phases': {}, 'cost': 0})
    a = h['attempts'][attempt-1]
    a['phases'][phase] = dur
    a['cost'] = round(a['cost'] + cost, 4)
print(json.dumps(h))
")
    fi
    CURRENT_PHASE="$new_phase"
    PHASE_START_EPOCH="$now"
    PHASE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    LAST_SESSION_COST=0.00
}

update_status() {
    local status="$1"
    local extra="${2:-}"
    sqlite3 "$DB_PATH" \
        "UPDATE loop_runs SET status='$status', updated_at=datetime('now') $extra WHERE id='$LOOP_RUN_ID'"
    start_phase "$status"
    write_live_status "$status" "${3:-$status}"
}

extract_cost_from_log() {
    # Extract total_cost_usd from the last "result" event in a log file
    local log_file="$1"
    local cost
    cost=$(grep '"type":"result"' "$log_file" 2>/dev/null \
        | tail -1 \
        | "$PYTHON" -c "import sys,json; print(json.loads(sys.stdin.readline()).get('total_cost_usd',0))" 2>/dev/null \
        || echo "0")
    echo "$cost"
}

accumulate_cost() {
    # Add cost from a log file to running total and update DB
    local log_file="$1"
    local session_cost
    session_cost=$(extract_cost_from_log "$log_file")
    LAST_SESSION_COST="$session_cost"
    TOTAL_COST=$("$PYTHON" -c "print(f'{$TOTAL_COST + $session_cost:.6f}')")
    log "Session cost: \$$session_cost | Total: \$$TOTAL_COST"
    sqlite3 "$DB_PATH" \
        "UPDATE loop_runs SET cost_usd=$TOTAL_COST, updated_at=datetime('now') WHERE id='$LOOP_RUN_ID'" \
        2>/dev/null || true
}

write_live_status() {
    local status="$1"
    local action="$2"
    local now_epoch
    now_epoch=$(date +%s)
    local started_epoch
    started_epoch=$(date -d "$STARTED_AT" +%s 2>/dev/null || date +%s)
    local elapsed_total=$(( now_epoch - started_epoch ))
    local phase_elapsed=0
    if [ -n "${PHASE_START_EPOCH:-}" ]; then
        phase_elapsed=$(( now_epoch - PHASE_START_EPOCH ))
    fi
    mkdir -p "$RUN_DIR/status"
    cat > "$RUN_DIR/status/${LOOP_RUN_ID}.json" << EOF
{
  "id": "${LOOP_RUN_ID}",
  "targetId": "${TARGET_ID:-}",
  "status": "${status}",
  "attempt": ${CURRENT_ATTEMPT:-0},
  "maxAttempts": ${MAX_ATTEMPTS},
  "currentAction": "${action}",
  "branch": "${BRANCH_NAME:-}",
  "worktree": "${WORKTREE_DIR:-}",
  "startedAt": "${STARTED_AT}",
  "phaseStartedAt": "${PHASE_STARTED_AT}",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "elapsedTotal": ${elapsed_total},
  "phaseElapsed": ${phase_elapsed},
  "costUsd": ${TOTAL_COST},
  "timingHistory": ${TIMING_HISTORY},
  "pid": $$
}
EOF
}

cleanup() {
    log "Worker cleanup"
    rm -f "$RUN_DIR/status/${LOOP_RUN_ID:-unknown}.json"
    rm -f "$BENCHMARK_LOCK.$$" 2>/dev/null || true
}
trap cleanup EXIT

install_role_settings() {
    # Install role-specific .claude/settings.json into the worktree
    # Usage: install_role_settings <role>
    # Roles: worker-research, worker-implement
    local role="$1"
    local src="$SCRIPT_DIR/settings/${role}.json"
    local dst="$WORKTREE_DIR/.claude/settings.json"
    if [ ! -f "$src" ]; then
        log "WARNING: Settings template not found: $src"
        return 1
    fi
    mkdir -p "$WORKTREE_DIR/.claude"
    # Replace placeholders with actual paths
    sed -e "s|__MCP_SERVER_PATH__|$SCRIPT_DIR/mcp-server.py|g" \
        -e "s|__PERF_DB_PATH__|$PERF_DB_PATH|g" \
        -e "s|__PERF_REPO_ROOT__|$PERF_REPO_ROOT|g" \
        "$src" > "$dst"
    log "Installed $role settings → $dst"
}

acquire_benchmark_lock() {
    while [ -f "$BENCHMARK_LOCK" ]; do
        log "Benchmark lock held — waiting..."
        sleep 10
    done
    echo "$LOOP_RUN_ID (PID $$)" > "$BENCHMARK_LOCK"
}

release_benchmark_lock() {
    rm -f "$BENCHMARK_LOCK"
}

run_claude() {
    local prompt_file="$1"
    local log_file="$2"
    local work_dir="${3:-$WORKTREE_DIR}"

    cd "$work_dir"
    # Write prompt to a temp file so we don't pipe into claude's stdin
    local prompt_tmp
    prompt_tmp=$(mktemp /tmp/perf-agent-prompt.XXXXXX)
    envsubst < "$prompt_file" > "$prompt_tmp"

    # Use stream-json for real-time output (--output-format text buffers everything)
    # Pipeline: claude -> tee (raw NDJSON to log) -> stream-fmt.py (formatted to terminal)
    # stdbuf -oL ensures line buffering through tee
    # python3 -u ensures unbuffered output from formatter
    stdbuf -oL claude -p \
        --output-format stream-json \
        --max-turns $MAX_TURNS \
        --verbose < "$prompt_tmp" 2>&1 \
        | stdbuf -oL tee -a "$log_file" \
        | python3 -u "$SCRIPT_DIR/stream-fmt.py"

    rm -f "$prompt_tmp"
    cd "$REPO_ROOT"
}

# ─── Phase 0: Claim target ──────────────────────────────────────────────────

log "Claiming target..."
mkdir -p "$RUN_DIR/logs"

CLAIM_JSON=$("$PYTHON" "$SCRIPT_DIR/claim_target.py" $CLAIM_ARGS --db "$DB_PATH")
CLAIM_EXIT=$?

if [ $CLAIM_EXIT -eq 2 ]; then
    log "No targets available. Exiting."
    exit 0
elif [ $CLAIM_EXIT -ne 0 ]; then
    log "Claim failed. Exiting."
    exit 1
fi

# Parse claim result
LOOP_RUN_ID=$(echo "$CLAIM_JSON" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin)['loop_run_id'])")
TARGET_ID=$(echo "$CLAIM_JSON" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin)['target_id'])")
BRANCH_NAME=$(echo "$CLAIM_JSON" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin)['branch'])")
DIFFICULTY=$(echo "$CLAIM_JSON" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin)['difficulty'])")
EXPECTED_IMPACT=$(echo "$CLAIM_JSON" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin)['impact'])")

log "Claimed: $TARGET_ID → $LOOP_RUN_ID (branch: $BRANCH_NAME)"

# Rename tmux session to show target
if [ -n "${TMUX:-}" ]; then
    tmux rename-session "W:${TARGET_ID}" 2>/dev/null || true
fi

# Export for prompt substitution
export TARGET_ID LOOP_RUN_ID BRANCH_NAME DIFFICULTY EXPECTED_IMPACT
export LOOP_STATE_DIR="loop-state/${LOOP_RUN_ID}"

# ─── Phase 0b: Create worktree ──────────────────────────────────────────────

WORKTREE_DIR="$WORKTREE_ROOT/${LOOP_RUN_ID,,}"
export WORKTREE_DIR

log "Creating worktree: $WORKTREE_DIR (branch: $BRANCH_NAME)"
mkdir -p "$WORKTREE_ROOT"
cd "$REPO_ROOT"
git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" perf-ai/setup

# Update DB with worktree path
sqlite3 "$DB_PATH" \
    "UPDATE loop_runs SET worktree_path='$WORKTREE_DIR' WHERE id='$LOOP_RUN_ID'"

# Create loop state dir inside worktree
mkdir -p "$WORKTREE_DIR/$LOOP_STATE_DIR"

# Initialize EF test submodule if not present (needed for correctness checks)
if [ ! -f "$WORKTREE_DIR/src/tests/.git" ] && [ ! -d "$WORKTREE_DIR/src/tests/.git" ]; then
    log "Initializing EF test submodule..."
    cd "$WORKTREE_DIR"
    git submodule update --init src/tests 2>/dev/null || \
        log "WARNING: Could not init EF test submodule (non-fatal)"
    cd "$REPO_ROOT"
fi

# Install research-phase settings (will be swapped before implement phase)
install_role_settings "worker-research"

write_live_status "research" "Worktree created, starting research"

# ─── Phase 1-2: Research + Hypothesize ───────────────────────────────────────

log "Phase 1-2: Research + Hypothesize"
update_status "research" "" "Running Claude Code for research..."

if $DRY_RUN; then
    log "[DRY-RUN] Skipping Claude Code research — generating stub artifacts"
    sleep 2  # brief pause for realism in dashboard
    cat > "$WORKTREE_DIR/$LOOP_STATE_DIR/hypothesis.md" << 'STUB_EOF'
# Hypothesis (dry-run)

This is a dry-run stub. No actual research was performed.

## Target
${TARGET_ID}

## Proposed Change
No-op for pipeline testing.

## Expected Impact
0% (dry-run mode)
STUB_EOF
else
    RESEARCH_LOG="$RUN_DIR/logs/${LOOP_RUN_ID}-research.log"
    run_claude "$PROMPTS_DIR/research.md" "$RESEARCH_LOG" "$WORKTREE_DIR"
    accumulate_cost "$RESEARCH_LOG"
fi

# Verify output
if [ ! -f "$WORKTREE_DIR/$LOOP_STATE_DIR/hypothesis.md" ]; then
    log "ERROR: Research phase produced no hypothesis.md"
    update_status "error" ", approach='Research failed: no hypothesis produced'"
    # Release target back to ready so another worker can try
    sqlite3 "$DB_PATH" \
        "UPDATE optimization_targets SET status='ready', updated_at=datetime('now') WHERE id='$TARGET_ID' AND status='active'" \
        2>/dev/null || true
    exit 1
fi

log "Research complete."

# Propose new targets discovered during research
if [ -f "$WORKTREE_DIR/$LOOP_STATE_DIR/new-targets.json" ]; then
    log "Found new target proposals, submitting..."
    PROPOSED=$("$PYTHON" "$SCRIPT_DIR/propose_target.py" \
        --from-file "$WORKTREE_DIR/$LOOP_STATE_DIR/new-targets.json" \
        --source "worker:$LOOP_RUN_ID" \
        --db "$DB_PATH" 2>&1) || true
    log "Target proposals: $PROPOSED"
fi

# Commit research artifacts
cd "$WORKTREE_DIR"
git add "$LOOP_STATE_DIR/"
git commit -m "perf(${TARGET_ID}): research + hypothesis [${LOOP_RUN_ID}]"
git push -u origin "$BRANCH_NAME"
cd "$REPO_ROOT"

# ─── Phase 3-5: Implement + Benchmark (loop) ────────────────────────────────

for CURRENT_ATTEMPT in $(seq 1 "$MAX_ATTEMPTS"); do
    export CURRENT_ATTEMPT
    export ATTEMPT_NUMBER="$CURRENT_ATTEMPT"
    export PREV_ATTEMPT=$((CURRENT_ATTEMPT - 1))

    log "Phase 3-5: Attempt $CURRENT_ATTEMPT/$MAX_ATTEMPTS"
    update_status "implementing" "" "Attempt $CURRENT_ATTEMPT — implementing..."

    if $DRY_RUN; then
        # ── Dry-run: skip Claude Code + benchmarks, insert fake 0% comparison ──
        log "[DRY-RUN] Skipping Claude Code + benchmarks for attempt $CURRENT_ATTEMPT"
        sleep 2

        # Create stub benchmark summary (no code changes, no real benchmarks)
        cat > "$WORKTREE_DIR/$LOOP_STATE_DIR/benchmark-summary.md" << 'STUB_EOF'
# Benchmark Summary (dry-run)

No benchmarks were executed. This is a pipeline test run.

| Metric | Baseline | Optimized | Delta |
|--------|----------|-----------|-------|
| N/A    | N/A      | N/A       | 0%    |
STUB_EOF

        # Insert a fake comparison row so evaluation logic has data
        sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO comparisons (
            loop_run_id, full_name, baseline_mean_ns, candidate_mean_ns,
            delta_mean_pct, is_significant, computed_at
        ) VALUES (
            '$LOOP_RUN_ID', 'dry-run-stub', 1000000, 1000000,
            0.0, 0, datetime('now')
        )" 2>/dev/null || true
    else
        # ── Real mode: Claude Code + benchmarks ──
        # Swap to implement-phase settings (full build/edit/test permissions, no web)
        install_role_settings "worker-implement"

        # Benchmark lock: hold during entire implement session.
        # Claude Code will run benchmarks as part of this session.
        # The lock ensures no other worker benchmarks simultaneously.
        acquire_benchmark_lock

        IMPL_LOG="$RUN_DIR/logs/${LOOP_RUN_ID}-impl-${CURRENT_ATTEMPT}.log"
        run_claude "$PROMPTS_DIR/implement.md" "$IMPL_LOG" "$WORKTREE_DIR"
        accumulate_cost "$IMPL_LOG"

        release_benchmark_lock
    fi

    # ── Correctness check (runs in both real and dry-run mode) ──
    CORRECTNESS_RESULT="$WORKTREE_DIR/$LOOP_STATE_DIR/correctness-result.json"
    if [ -f "$CORRECTNESS_RESULT" ]; then
        CORRECTNESS_STATUS=$("$PYTHON" -c "import sys,json; print(json.load(open('$CORRECTNESS_RESULT'))['result'])" 2>/dev/null || echo "unknown")
        if [ "$CORRECTNESS_STATUS" = "fail" ]; then
            log "CORRECTNESS CHECK FAILED — skipping benchmark evaluation"
            update_status "error" ", approach='Attempt $CURRENT_ATTEMPT: correctness check failed'" \
                "Attempt $CURRENT_ATTEMPT failed — correctness tests failed"
            cd "$WORKTREE_DIR"
            git add -A && git commit -m "perf(${TARGET_ID}): attempt ${CURRENT_ATTEMPT} — correctness failed [${LOOP_RUN_ID}]" || true
            git push origin "$BRANCH_NAME" || true
            cd "$REPO_ROOT"
            continue
        fi
        log "Correctness check: $CORRECTNESS_STATUS"
    fi

    # ── Check if results exist ──
    COMPARISON_COUNT=$(sqlite3 "$DB_PATH" \
        "SELECT COUNT(*) FROM comparisons WHERE loop_run_id='$LOOP_RUN_ID'" 2>/dev/null || echo "0")

    if [ "$COMPARISON_COUNT" = "0" ]; then
        # Claude may not have ingested. Try running compare manually.
        RESULT_COUNT=$(sqlite3 "$DB_PATH" \
            "SELECT COUNT(*) FROM benchmark_results WHERE loop_run_id='$LOOP_RUN_ID'" 2>/dev/null || echo "0")
        if [ "$RESULT_COUNT" != "0" ]; then
            log "Running compare.py manually..."
            "$PYTHON" "$REPO_ROOT/tools/perf-dashboard/scripts/compare.py" \
                --loop-run "$LOOP_RUN_ID" --db "$DB_PATH" || true
        else
            log "No benchmark results produced"
            update_status "error" ", approach='Attempt $CURRENT_ATTEMPT: no benchmark results'" \
                "Attempt $CURRENT_ATTEMPT failed — no benchmark results"
            # Commit what we have and try again
            cd "$WORKTREE_DIR"
            git add -A && git commit -m "perf(${TARGET_ID}): attempt ${CURRENT_ATTEMPT} — no results [${LOOP_RUN_ID}]" || true
            git push origin "$BRANCH_NAME" || true
            cd "$REPO_ROOT"
            continue
        fi
    fi

    # ── Evaluate results ──
    BEST_DELTA=$(sqlite3 "$DB_PATH" \
        "SELECT MIN(delta_mean_pct) FROM comparisons WHERE loop_run_id='$LOOP_RUN_ID' AND is_significant=1" \
        2>/dev/null || echo "")
    REGRESSIONS=$(sqlite3 "$DB_PATH" \
        "SELECT COUNT(*) FROM comparisons WHERE loop_run_id='$LOOP_RUN_ID' AND is_significant=1 AND delta_mean_pct > 5" \
        2>/dev/null || echo "0")

    log "Results: best_delta=${BEST_DELTA:-none}, regressions=$REGRESSIONS"

    # In dry-run mode, skip the improvement threshold — go straight to pending_decision
    if $DRY_RUN; then
        log "[DRY-RUN] Skipping improvement threshold — requesting human decision (0% delta)"
        update_status "pending_decision" \
            ", approach='dry-run: no code changes, 0% delta'" \
            "Waiting for human review (dry-run, 0% delta)"

        cd "$WORKTREE_DIR"
        git add -A
        git commit -m "perf(${TARGET_ID}): dry-run attempt ${CURRENT_ATTEMPT} — pipeline test [${LOOP_RUN_ID}]" || true
        git push origin "$BRANCH_NAME"
        cd "$REPO_ROOT"

        break  # exit attempt loop, go to decision wait
    fi

    # Check: >= 5% improvement AND no regressions
    IMPROVED=0
    if [ -n "$BEST_DELTA" ] && [ "$REGRESSIONS" -eq 0 ]; then
        IMPROVED=$("$PYTHON" -c "print(1 if float('${BEST_DELTA}') <= -5.0 else 0)" 2>/dev/null || echo 0)
    fi

    if [ "$IMPROVED" -eq 1 ]; then
        log "IMPROVEMENT: ${BEST_DELTA}% — requesting human decision"
        update_status "pending_decision" "" "Waiting for human review (${BEST_DELTA}% improvement)"

        cd "$WORKTREE_DIR"
        git add -A
        git commit -m "perf(${TARGET_ID}): attempt ${CURRENT_ATTEMPT} — ${BEST_DELTA}% improvement [${LOOP_RUN_ID}]" || true
        git push origin "$BRANCH_NAME"
        cd "$REPO_ROOT"

        break  # exit attempt loop, go to decision wait
    fi

    # Not enough improvement
    if [ "$CURRENT_ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
        log "Attempt $CURRENT_ATTEMPT: insufficient improvement. Retrying."
        update_status "iterating" \
            ", approach='Attempt $CURRENT_ATTEMPT: delta=${BEST_DELTA:-none}'" \
            "Preparing retry (attempt $((CURRENT_ATTEMPT+1)))"

        cd "$WORKTREE_DIR"
        git add -A
        git commit -m "perf(${TARGET_ID}): attempt ${CURRENT_ATTEMPT} — no improvement [${LOOP_RUN_ID}]" || true
        git push origin "$BRANCH_NAME" || true
        cd "$REPO_ROOT"
    else
        log "All attempts exhausted."
        # Mark target as exhausted in backlog
        sqlite3 "$DB_PATH" \
            "UPDATE optimization_targets SET status='exhausted', updated_at=datetime('now') WHERE id='$TARGET_ID' AND status='active'" \
            2>/dev/null || true
        "$PYTHON" "$REPO_ROOT/tools/perf-dashboard/scripts/verdict.py" \
            --loop-run "$LOOP_RUN_ID" --verdict inconclusive \
            --notes "Exhausted $MAX_ATTEMPTS attempts. Best delta: ${BEST_DELTA:-none}" \
            --db "$DB_PATH" || true

        cd "$WORKTREE_DIR"
        git add -A
        git commit -m "perf(${TARGET_ID}): all attempts exhausted [${LOOP_RUN_ID}]" || true
        git push origin "$BRANCH_NAME" || true
        cd "$REPO_ROOT"

        # Cleanup worktree
        git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true

        log "Worker finished (inconclusive)"
        exit 0
    fi
done

# ─── Phase 6: Wait for human decision ───────────────────────────────────────

log "Awaiting human verdict at http://localhost:4040"

MAX_WAIT=$((24 * 3600))
WAIT_START=$(date +%s)

while true; do
    VERDICT=$(sqlite3 "$DB_PATH" \
        "SELECT verdict FROM loop_runs WHERE id='$LOOP_RUN_ID'" 2>/dev/null || echo "")

    if [ -n "$VERDICT" ] && [ "$VERDICT" != "" ]; then
        log "Verdict: $VERDICT"
        break
    fi

    ELAPSED=$(( $(date +%s) - WAIT_START ))
    if [ "$ELAPSED" -gt "$MAX_WAIT" ]; then
        log "Timeout (24h). Marking inconclusive."
        "$PYTHON" "$REPO_ROOT/tools/perf-dashboard/scripts/verdict.py" \
            --loop-run "$LOOP_RUN_ID" --verdict inconclusive \
            --notes "Timed out waiting for human review" --db "$DB_PATH" || true
        break
    fi

    write_live_status "pending_decision" "Waiting for human review (${ELAPSED}s)"
    sleep "$DECISION_POLL_INTERVAL"
done

# ─── React to verdict ────────────────────────────────────────────────────────

if [ "$VERDICT" = "improvement" ]; then
    log "APPROVED"
    # Branch is already pushed. PR was created by decision-server.
    # Just clean up worktree.
else
    log "DISCARDED ($VERDICT)"
    # Delete remote branch
    git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
fi

# Clean up worktree
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true

log "Worker complete ($VERDICT)."
