#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# start.sh — Launch the perf-ai agent system in a zellij session
#
# Creates a zellij session "perf-agents" with tabs:
#   [server] [worker-1] [worker-2] ... [worker-N]
#
# Usage:
#   ./tools/perf-agents/start.sh                    # 2 workers (default)
#   ./tools/perf-agents/start.sh --workers 3        # 3 workers
#   ./tools/perf-agents/start.sh --target EVM-1     # specific target (1 worker)
#   ./tools/perf-agents/start.sh --server-only      # just dashboard server
#   ./tools/perf-agents/start.sh --workers-only     # just workers, no server
#
# Attach later:  bash tools/perf-agents/attach.sh
# Stop:          bash tools/perf-agents/stop.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
SESSION_NAME="perf-agents"

# ── Validate dependencies ────────────────────────────────────────────────────

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: '$1' not found. $2"
        exit 1
    fi
}

check_cmd zellij "Install: cargo install zellij (or download from https://zellij.dev)"
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers)       WORKERS="$2"; shift 2 ;;
        --target)        TARGET="$2"; shift 2 ;;
        --exclude)       EXCLUDE="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --server-only)   SERVER_ONLY=true; shift ;;
        --workers-only)  WORKERS_ONLY=true; shift ;;
        -h|--help)
            echo "Usage: start.sh [--workers N] [--target ID] [--exclude IDs] [--port N] [--server-only] [--workers-only]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if $SERVER_ONLY && $WORKERS_ONLY; then
    echo "ERROR: --server-only and --workers-only are mutually exclusive."
    exit 1
fi

# Force 1 worker when targeting a specific ID
if [ -n "$TARGET" ]; then
    WORKERS=1
fi

# ── Create directories ────────────────────────────────────────────────────────

mkdir -p "$RUN_DIR/logs" "$RUN_DIR/status" "$REPO_ROOT/.worktrees"

# ── Ensure .worktrees is gitignored ──────────────────────────────────────────

if ! grep -q "^\.worktrees/" "$REPO_ROOT/.gitignore" 2>/dev/null; then
    echo ".worktrees/" >> "$REPO_ROOT/.gitignore"
    echo "[init] Added .worktrees/ to .gitignore"
fi

# ── Initialize DB ─────────────────────────────────────────────────────────────

DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
if [ ! -f "$DB_PATH" ]; then
    echo "[init] Creating database..."
    python3 "$REPO_ROOT/tools/perf-dashboard/scripts/init_db.py" --db "$DB_PATH"
fi

# ── Kill existing session if any ──────────────────────────────────────────────

if zellij list-sessions 2>/dev/null | grep -q "^${SESSION_NAME}"; then
    echo "[init] Killing existing '$SESSION_NAME' session..."
    zellij kill-session "$SESSION_NAME" 2>/dev/null || true
    sleep 1
fi

# ── Build worker args string for KDL ─────────────────────────────────────────

build_worker_args() {
    local args=""
    if [ -n "$TARGET" ]; then
        args="        args \"--target\" \"$TARGET\"\n"
    fi
    if [ -n "$EXCLUDE" ]; then
        args="${args}        args \"--exclude\" \"$EXCLUDE\"\n"
    fi
    echo -ne "$args"
}

# ── Generate KDL layout ──────────────────────────────────────────────────────

LAYOUT_FILE="$RUN_DIR/perf-agents.kdl"

{
    echo 'layout {'

    # Server tab
    if ! $WORKERS_ONLY; then
        cat <<SERVERTAB
    tab name="server" focus=true {
        pane command="python3" {
            args "tools/perf-agents/decision-server.py" "--port" "$PORT"
            cwd "$REPO_ROOT"
        }
    }
SERVERTAB
    fi

    # Worker tabs
    if ! $SERVER_ONLY; then
        for i in $(seq 1 "$WORKERS"); do
            FOCUS=""
            if $WORKERS_ONLY && [ "$i" -eq 1 ]; then
                FOCUS=" focus=true"
            fi
            echo "    tab name=\"worker-$i\"$FOCUS {"
            echo '        pane command="bash" {'
            # Build the args line: always start with the worker script path
            ARGS_LINE="            args \"tools/perf-agents/worker.sh\""
            if [ -n "$TARGET" ]; then
                ARGS_LINE="$ARGS_LINE \"--target\" \"$TARGET\""
            fi
            if [ -n "$EXCLUDE" ]; then
                ARGS_LINE="$ARGS_LINE \"--exclude\" \"$EXCLUDE\""
            fi
            echo "$ARGS_LINE"
            echo "            cwd \"$REPO_ROOT\""
            echo '        }'
            echo '    }'
        done
    fi

    echo '}'
} > "$LAYOUT_FILE"

# ── Launch ────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERF-AI AGENT SYSTEM (zellij)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Session:    $SESSION_NAME"
echo "  Workers:    $WORKERS"
if [ -n "$TARGET" ]; then
    echo "  Target:     $TARGET"
fi
echo "  Dashboard:  http://localhost:$PORT"
echo "  Layout:     $LAYOUT_FILE"
echo ""
echo "  Detach:     Ctrl+O, d"
echo "  Reattach:   bash tools/perf-agents/attach.sh"
echo "  Stop:       bash tools/perf-agents/stop.sh"
echo "  Navigate:   Alt+<number> to switch tabs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exec zellij --session "$SESSION_NAME" --layout "$LAYOUT_FILE"
