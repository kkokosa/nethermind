#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# start.sh — Launch the perf-ai agent system as independent tmux sessions
#
# Each component runs in its own tmux session (fully decoupled lifecycle):
#   perf-server     →  decision-server.py (port 4040)
#   perf-worker-1   →  worker.sh (claims target, runs optimization loop)
#   perf-worker-2   →  worker.sh
#   ...
#
# Usage:
#   ./tools/perf-agents/start.sh                    # server + 2 workers (default)
#   ./tools/perf-agents/start.sh --workers 3        # server + 3 workers
#   ./tools/perf-agents/start.sh --target EVM-1     # specific target (1 worker)
#   ./tools/perf-agents/start.sh --server-only      # just dashboard server
#   ./tools/perf-agents/start.sh --workers-only     # just workers, no server
#   ./tools/perf-agents/start.sh --worker            # add one more worker to fleet
#   ./tools/perf-agents/start.sh --worker --target X # add one worker for target X
#
# Attach later:  bash tools/perf-agents/attach.sh
# Stop:          bash tools/perf-agents/stop.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"

# ── Validate dependencies ────────────────────────────────────────────────────

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: '$1' not found. $2"
        exit 1
    fi
}

check_cmd tmux "Install: sudo apt install tmux"
check_cmd python3 "Install Python 3 and ensure python3 is on PATH."
check_cmd claude "Install Claude Code CLI."
check_cmd sqlite3 "Install sqlite3."

# ── Parse args ────────────────────────────────────────────────────────────────

WORKERS=2
TARGET=""
EXCLUDE=""
PORT=4040
SERVER_ONLY=false
WORKERS_ONLY=false
SINGLE_WORKER=false
BUILD_UI=false
RESEARCHER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers)       WORKERS="$2"; shift 2 ;;
        --worker)        SINGLE_WORKER=true; shift ;;
        --target)        TARGET="$2"; shift 2 ;;
        --exclude)       EXCLUDE="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --server-only)   SERVER_ONLY=true; shift ;;
        --workers-only)  WORKERS_ONLY=true; shift ;;
        --build)         BUILD_UI=true; shift ;;
        --researcher)    RESEARCHER=true; shift ;;
        -h|--help)
            echo "Usage: start.sh [--workers N] [--worker] [--target ID] [--exclude IDs] [--port N] [--server-only] [--workers-only] [--build] [--researcher]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if $SERVER_ONLY && $WORKERS_ONLY; then
    echo "ERROR: --server-only and --workers-only are mutually exclusive."
    exit 1
fi

# --worker mode: add exactly one worker to the existing fleet
if $SINGLE_WORKER; then
    WORKERS=1
    WORKERS_ONLY=true
fi

# Force 1 worker when targeting a specific ID
if [ -n "$TARGET" ] && ! $SERVER_ONLY; then
    WORKERS=1
fi

# ── Create directories ────────────────────────────────────────────────────────

mkdir -p "$RUN_DIR/logs" "$RUN_DIR/status" "$REPO_ROOT/.worktrees"

# ── Purge stale status files from previous runs ──────────────────────────────

for f in "$RUN_DIR/status/"*.json; do
    [ -f "$f" ] || continue
    pid=$(python3 -c "import json; print(json.load(open('$f')).get('pid',0))" 2>/dev/null || echo 0)
    if [ "$pid" != "0" ] && ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$f"
    fi
done

# ── Ensure .worktrees is gitignored ──────────────────────────────────────────

if ! grep -q "^\.worktrees/" "$REPO_ROOT/.gitignore" 2>/dev/null; then
    echo ".worktrees/" >> "$REPO_ROOT/.gitignore"
    echo "[init] Added .worktrees/ to .gitignore"
fi

# ── Initialize DB ─────────────────────────────────────────────────────────────

DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
echo "[init] Initializing database (+ migrations)..."
python3 "$REPO_ROOT/tools/perf-dashboard/scripts/init_db.py" --db "$DB_PATH"

# ── Seed backlog from markdown (idempotent) ──────────────────────────────────

echo "[init] Seeding optimization backlog..."
python3 "$SCRIPT_DIR/backlog.py" --db "$DB_PATH" \
    --targets-file "$REPO_ROOT/docs/perf-ai/OPTIMIZATION-TARGETS.md" seed || {
    echo "WARNING: Backlog seeding failed (non-fatal)"
}

# ── Helper: find next available worker number ────────────────────────────────

next_worker_number() {
    local n=1
    while tmux has-session -t "perf-worker-${n}" 2>/dev/null || \
          tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -q "^W:.*"; do
        # Check both perf-worker-N and renamed W:* sessions
        if tmux has-session -t "perf-worker-${n}" 2>/dev/null; then
            n=$((n + 1))
        else
            break
        fi
    done
    echo "$n"
}

# ── Launch server session ─────────────────────────────────────────────────────

# ── Build dashboard UI ────────────────────────────────────────────────────

if $BUILD_UI; then
    DASHBOARD_DIR="$REPO_ROOT/tools/perf-dashboard/dashboard"
    echo "[build] Building dashboard UI..."
    (cd "$DASHBOARD_DIR" && npm install --silent && npm run build) || {
        echo "WARNING: Dashboard build failed. Server will still start."
    }
fi

if ! $WORKERS_ONLY; then
    if tmux has-session -t perf-server 2>/dev/null; then
        echo "[server] Session 'perf-server' already running — skipping"
    else
        tmux new-session -d -s perf-server -c "$REPO_ROOT" \
            "python3 tools/perf-agents/decision-server.py --port $PORT; echo '[server exited — press Enter to close]'; read"
        echo "[server] Started tmux session 'perf-server' (port $PORT)"
    fi
fi

# ── Launch worker sessions ────────────────────────────────────────────────────

if ! $SERVER_ONLY; then
    START_NUM=$(next_worker_number)
    for i in $(seq 0 $((WORKERS - 1))); do
        WORKER_NUM=$((START_NUM + i))
        SESSION_NAME="perf-worker-${WORKER_NUM}"

        WORKER_CMD="bash tools/perf-agents/worker.sh"
        if [ -n "$TARGET" ]; then
            WORKER_CMD="$WORKER_CMD --target $TARGET"
        fi
        if [ -n "$EXCLUDE" ]; then
            WORKER_CMD="$WORKER_CMD --exclude $EXCLUDE"
        fi

        tmux new-session -d -s "$SESSION_NAME" -c "$REPO_ROOT" \
            "$WORKER_CMD; echo '[worker exited — press Enter to close]'; read"
        echo "[worker] Started tmux session '$SESSION_NAME'"
    done
fi

# ── Launch researcher session ────────────────────────────────────────────────

if $RESEARCHER; then
    if tmux has-session -t perf-researcher 2>/dev/null; then
        echo "[researcher] Session 'perf-researcher' already running — skipping"
    else
        tmux new-session -d -s perf-researcher -c "$REPO_ROOT" \
            "bash tools/perf-agents/researcher.sh; echo '[researcher exited — press Enter to close]'; read"
        echo "[researcher] Started tmux session 'perf-researcher'"
    fi
fi

# ── Print status summary ─────────────────────────────────────────────────────

echo ""
echo "=================================================="
echo "  PERF-AI AGENT SYSTEM (tmux)"
echo "=================================================="

# List all active perf sessions
SESSIONS=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^perf-\|^W:\|^W_" | sort || true)
if [ -n "$SESSIONS" ]; then
    echo "  Active sessions:"
    echo "$SESSIONS" | while read -r s; do
        echo "    - $s"
    done
else
    echo "  No active sessions"
fi

echo ""
echo "  Dashboard:  http://localhost:$PORT"
echo ""
echo "  Attach:     bash tools/perf-agents/attach.sh server"
echo "              bash tools/perf-agents/attach.sh worker-1"
echo "  Detach:     Ctrl+B, d"
echo "  Stop:       bash tools/perf-agents/stop.sh"
echo "  Status:     python3 tools/perf-agents/orchestrate.py --status"
echo "=================================================="
echo ""
