#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# start-dummy.sh — Launch dummy workers for testing the dashboard UI
#
# Usage:
#   bash tools/perf-agents/start-dummy.sh                   # 2 dummy workers
#   bash tools/perf-agents/start-dummy.sh --workers 3       # 3 dummy workers
#   bash tools/perf-agents/start-dummy.sh --pending          # hold at pending_decision
#   bash tools/perf-agents/start-dummy.sh --speed fast       # fast transitions
#   bash tools/perf-agents/start-dummy.sh --fail             # simulate failures
#
# Stop:  bash tools/perf-agents/stop-dummy.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORKERS=2
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers)   WORKERS="$2"; shift 2 ;;
        --speed)     EXTRA_ARGS="$EXTRA_ARGS --speed $2"; shift 2 ;;
        --fail)      EXTRA_ARGS="$EXTRA_ARGS --fail"; shift ;;
        --pending)   EXTRA_ARGS="$EXTRA_ARGS --pending"; shift ;;
        -h|--help)
            echo "Usage: start-dummy.sh [--workers N] [--speed fast|normal|slow] [--fail] [--pending]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

mkdir -p "$SCRIPT_DIR/run/status" "$SCRIPT_DIR/run/logs"

# Ensure DB exists and backlog is seeded
DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
python3 "$REPO_ROOT/tools/perf-dashboard/scripts/init_db.py" --db "$DB_PATH"
python3 "$SCRIPT_DIR/backlog.py" --db "$DB_PATH" \
    --targets-file "$REPO_ROOT/docs/perf-ai/OPTIMIZATION-TARGETS.md" seed || true

for i in $(seq 1 "$WORKERS"); do
    SESSION_NAME="perf-dummy-${i}"

    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "[dummy] Session '$SESSION_NAME' already running — skipping"
        continue
    fi

    tmux new-session -d -s "$SESSION_NAME" -c "$REPO_ROOT" \
        "bash tools/perf-agents/dummy-worker.sh $EXTRA_ARGS; echo '[dummy worker exited — press Enter]'; read"
    echo "[dummy] Started tmux session '$SESSION_NAME'"
done

echo ""
echo "  Dummy workers: $WORKERS"
echo "  Dashboard:     http://localhost:4040"
echo "  Stop:          bash tools/perf-agents/stop-dummy.sh"
echo ""
