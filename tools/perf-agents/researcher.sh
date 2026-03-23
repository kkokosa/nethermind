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

# Export env vars for MCP server
export PERF_DB_PATH="$DB_PATH"
export PERF_REPO_ROOT="$REPO_ROOT"

mkdir -p "$RUN_DIR/logs"

log() {
    echo "[$(date -u +%H:%M:%S)] [RESEARCHER] $*"
}

# Install researcher settings and clean up on exit
install_researcher_settings() {
    local src="$SCRIPT_DIR/settings/researcher.json"
    local dst="$REPO_ROOT/.claude/settings.json"
    if [ ! -f "$src" ]; then
        log "WARNING: Settings template not found: $src"
        return 1
    fi
    mkdir -p "$REPO_ROOT/.claude"
    sed -e "s|__MCP_SERVER_PATH__|$SCRIPT_DIR/mcp-server.py|g" \
        -e "s|__PERF_DB_PATH__|$PERF_DB_PATH|g" \
        -e "s|__PERF_REPO_ROOT__|$PERF_REPO_ROOT|g" \
        "$src" > "$dst"
    log "Installed researcher settings → $dst"
}

cleanup_researcher_settings() {
    rm -f "$REPO_ROOT/.claude/settings.json"
    log "Removed researcher settings"
}
trap cleanup_researcher_settings EXIT

install_researcher_settings

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
