#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# stop.sh — Stop the perf-ai agent system (tmux sessions)
#
# Granular control over which sessions to kill:
#   ./tools/perf-agents/stop.sh                  # kill all perf-* sessions + cleanup
#   ./tools/perf-agents/stop.sh --server-only    # kill perf-server only
#   ./tools/perf-agents/stop.sh --workers-only   # kill all perf-worker-* sessions
#   ./tools/perf-agents/stop.sh --worker 2       # kill perf-worker-2 only
#   ./tools/perf-agents/stop.sh --force          # also remove all worktrees
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
FORCE=false
SERVER_ONLY=false
WORKERS_ONLY=false
SINGLE_WORKER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)         FORCE=true; shift ;;
        --server-only)   SERVER_ONLY=true; shift ;;
        --workers-only)  WORKERS_ONLY=true; shift ;;
        --worker)        SINGLE_WORKER="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: stop.sh [--force] [--server-only] [--workers-only] [--worker N]"
            echo "  (no flags)     Kill all perf-* sessions + cleanup"
            echo "  --server-only  Kill perf-server only"
            echo "  --workers-only Kill all perf-worker-* / W:* sessions"
            echo "  --worker N     Kill perf-worker-N (or W:* renamed session)"
            echo "  --force        Also remove all worktrees without prompting"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if $SERVER_ONLY && $WORKERS_ONLY; then
    echo "ERROR: --server-only and --workers-only are mutually exclusive."
    exit 1
fi

echo "Stopping perf-ai agent system..."

# ── Helper: kill a tmux session by name (tolerates missing) ──────────────────

kill_session() {
    local name="$1"
    if tmux has-session -t "$name" 2>/dev/null; then
        tmux kill-session -t "$name" 2>/dev/null || true
        echo "  Killed session '$name'"
        return 0
    fi
    return 1
}

# ── Kill specific worker ─────────────────────────────────────────────────────

if [ -n "$SINGLE_WORKER" ]; then
    if ! kill_session "perf-worker-${SINGLE_WORKER}"; then
        # Try W:* renamed sessions — search all sessions
        echo "  No session 'perf-worker-${SINGLE_WORKER}' found"
    fi
    echo ""
    echo "Done. Remaining sessions:"
    tmux list-sessions -F "  #{session_name}" 2>/dev/null | grep "perf-\|W:" || echo "  (none)"
    exit 0
fi

# ── Kill server ──────────────────────────────────────────────────────────────

if ! $WORKERS_ONLY; then
    kill_session "perf-server" || echo "  No 'perf-server' session found"
fi

# ── Kill workers ─────────────────────────────────────────────────────────────

if ! $SERVER_ONLY; then
    KILLED=0
    for s in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^perf-worker-\|^W:" || true); do
        kill_session "$s" && KILLED=$((KILLED + 1))
    done
    if [ "$KILLED" -eq 0 ]; then
        echo "  No worker sessions found"
    fi
fi

# ── Clean up runtime files ────────────────────────────────────────────────────

if ! $SERVER_ONLY && ! $WORKERS_ONLY && [ -z "$SINGLE_WORKER" ]; then
    # Full cleanup only when stopping everything
    rm -f "$RUN_DIR/status/"*.json 2>/dev/null || true
    rm -f "$RUN_DIR/benchmark.lock" 2>/dev/null || true
    rm -f "$RUN_DIR/server.pid" 2>/dev/null || true
    rm -f "$RUN_DIR/workers.pid" 2>/dev/null || true
    echo "  Cleaned up runtime files"
fi

# ── Handle worktrees ─────────────────────────────────────────────────────────

WORKTREE_DIR="$REPO_ROOT/.worktrees"
if [ -d "$WORKTREE_DIR" ]; then
    WORKTREE_COUNT=$(find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "$WORKTREE_COUNT" -gt 0 ]; then
        echo ""
        echo "  Found $WORKTREE_COUNT worktree(s):"
        ls -1 "$WORKTREE_DIR/"
        echo ""

        REMOVE_WORKTREES=false
        if $FORCE; then
            REMOVE_WORKTREES=true
        else
            read -rp "  Remove all worktrees? [y/N] " answer
            case "$answer" in
                [yY]|[yY][eE][sS]) REMOVE_WORKTREES=true ;;
            esac
        fi

        if $REMOVE_WORKTREES; then
            for wt in "$WORKTREE_DIR"/*/; do
                [ -d "$wt" ] || continue
                wt_name=$(basename "$wt")
                git -C "$REPO_ROOT" worktree remove "$wt" --force 2>/dev/null || {
                    echo "  Warning: git worktree remove failed for $wt_name, removing directory"
                    rm -rf "$wt"
                }
                echo "  Removed worktree: $wt_name"
            done
            git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
            echo "  All worktrees cleaned up"
        else
            echo "  Worktrees left in place."
            echo "  To clean later: git worktree list && git worktree prune"
        fi
    fi
fi

echo ""
echo "Done."
