#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# researcher.sh — Discover new optimization targets via Claude Code
#
# Runs in the repo root (read-only research, no worktree needed).
# Loop: query backlog -> run Claude -> propose targets -> sleep.
#
# Usage:
#   bash tools/perf-agents/researcher.sh
#
# Environment:
#   RESEARCHER_INTERVAL  — seconds between cycles (default: 3600)
#   RESEARCHER_MAX_CYCLES — max cycles before exit (default: 24)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
PROMPTS_DIR="$SCRIPT_DIR/PROMPTS"
RUN_DIR="$SCRIPT_DIR/run"

PYTHON="python3"
SLEEP_BETWEEN=${RESEARCHER_INTERVAL:-3600}
MAX_CYCLES=${RESEARCHER_MAX_CYCLES:-24}
MAX_TURNS=30

mkdir -p "$RUN_DIR/logs"

log() {
    echo "[$(date -u +%H:%M:%S)] [RESEARCHER] $*"
}

for cycle in $(seq 1 "$MAX_CYCLES"); do
    log "Cycle $cycle/$MAX_CYCLES"

    # Get backlog summary for prompt context
    BACKLOG_SUMMARY=$("$PYTHON" "$SCRIPT_DIR/backlog.py" status --json --db "$DB_PATH" 2>/dev/null || echo '{}')
    export BACKLOG_SUMMARY

    RESEARCH_OUTPUT_DIR="$RUN_DIR/researcher-cycle-${cycle}"
    mkdir -p "$RESEARCH_OUTPUT_DIR"
    export RESEARCH_OUTPUT_DIR

    # Render prompt
    PROMPT_TMP=$(mktemp /tmp/perf-researcher-prompt.XXXXXX)
    envsubst < "$PROMPTS_DIR/researcher.md" > "$PROMPT_TMP"

    LOG_FILE="$RUN_DIR/logs/researcher-$(date +%Y%m%d-%H%M%S).log"
    log "Running Claude Code..."

    cd "$REPO_ROOT"
    stdbuf -oL claude -p \
        --output-format stream-json \
        --max-turns "$MAX_TURNS" \
        --verbose < "$PROMPT_TMP" 2>&1 \
        | stdbuf -oL tee -a "$LOG_FILE" \
        | "$PYTHON" -u "$SCRIPT_DIR/stream-fmt.py" \
        || true

    rm -f "$PROMPT_TMP"

    # Ingest any proposals
    if [ -f "$RESEARCH_OUTPUT_DIR/new-targets.json" ]; then
        log "Found proposals, submitting..."
        PROPOSED=$("$PYTHON" "$SCRIPT_DIR/propose_target.py" \
            --from-file "$RESEARCH_OUTPUT_DIR/new-targets.json" \
            --source "researcher" \
            --db "$DB_PATH" 2>&1) || true
        log "Proposals: $PROPOSED"
    else
        log "No proposals generated this cycle"
    fi

    if [ "$cycle" -lt "$MAX_CYCLES" ]; then
        log "Sleeping ${SLEEP_BETWEEN}s until next cycle..."
        sleep "$SLEEP_BETWEEN"
    fi
done

log "Researcher finished ($MAX_CYCLES cycles)"
