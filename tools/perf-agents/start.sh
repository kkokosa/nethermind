#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# start.sh — Launch the perf-ai agent system
#
# Usage:
#   ./tools/perf-agents/start.sh                    # 2 workers (default)
#   ./tools/perf-agents/start.sh --workers 3        # 3 workers
#   ./tools/perf-agents/start.sh --target EVM-1     # specific target
#   ./tools/perf-agents/start.sh --dashboard-only   # just dashboard
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"

WORKERS=2
TARGET=""
EXCLUDE=""
DASHBOARD_ONLY=false
PORT=4040

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers)        WORKERS="$2"; shift 2 ;;
        --target)         TARGET="$2"; shift 2 ;;
        --exclude)        EXCLUDE="$2"; shift 2 ;;
        --port)           PORT="$2"; shift 2 ;;
        --dashboard-only) DASHBOARD_ONLY=true; shift ;;
        -h|--help)
            echo "Usage: start.sh [--workers N] [--target ID] [--exclude IDs] [--port N] [--dashboard-only]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

mkdir -p "$RUN_DIR" "$REPO_ROOT/.worktrees"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERF-AI AGENT SYSTEM"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Ensure .worktrees is gitignored ──
if ! grep -q "^\.worktrees/" "$REPO_ROOT/.gitignore" 2>/dev/null; then
    echo ".worktrees/" >> "$REPO_ROOT/.gitignore"
    echo "[init] Added .worktrees/ to .gitignore"
fi

# ── Initialize DB ──
DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
if [ ! -f "$DB_PATH" ]; then
    echo "[init] Creating database..."
    python3 "$REPO_ROOT/tools/perf-dashboard/scripts/init_db.py" --db "$DB_PATH"
fi

# ── Start decision server ──
echo "[server] Starting on port $PORT..."
python3 "$SCRIPT_DIR/decision-server.py" --port "$PORT" &
SERVER_PID=$!
echo "$SERVER_PID" > "$RUN_DIR/server.pid"
sleep 1

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[server] FAILED"
    exit 1
fi
echo "[server] http://localhost:$PORT (PID $SERVER_PID)"

if $DASHBOARD_ONLY; then
    echo ""
    echo "Dashboard-only mode. Press Ctrl+C to stop."
    wait "$SERVER_PID"
    exit 0
fi

# ── Spawn workers ──
echo ""
ORCH_ARGS="--workers $WORKERS"
[ -n "$TARGET" ] && ORCH_ARGS="--target $TARGET"
[ -n "$EXCLUDE" ] && ORCH_ARGS="$ORCH_ARGS --exclude $EXCLUDE"

python3 "$SCRIPT_DIR/orchestrate.py" $ORCH_ARGS

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Dashboard:  http://localhost:$PORT"
echo "  Status:     python3 $SCRIPT_DIR/orchestrate.py --status"
echo "  Stop:       bash $SCRIPT_DIR/stop_all.sh"
echo "  Logs:       $RUN_DIR/logs/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
