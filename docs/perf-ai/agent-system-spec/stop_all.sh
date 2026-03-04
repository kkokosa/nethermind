#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"

echo "Stopping perf-ai agent system..."

# Kill decision server
if [ -f "$RUN_DIR/server.pid" ]; then
    PID=$(cat "$RUN_DIR/server.pid")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"; echo "  Stopped server (PID $PID)"
    fi
    rm -f "$RUN_DIR/server.pid"
fi

# Kill workers
if [ -f "$RUN_DIR/workers.pid" ]; then
    while read -r pid; do
        [ -z "$pid" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
            echo "  Stopped worker PID $pid"
        fi
    done < "$RUN_DIR/workers.pid"
    rm -f "$RUN_DIR/workers.pid"
fi

# Clean status files + lock
rm -f "$RUN_DIR/status/"*.json 2>/dev/null || true
rm -f "$RUN_DIR/benchmark.lock" 2>/dev/null || true

echo "All agents stopped."
echo ""

# Show orphaned worktrees (don't auto-remove — might want to inspect)
if [ -d "$REPO_ROOT/.worktrees" ]; then
    WORKTREES=$(ls "$REPO_ROOT/.worktrees" 2>/dev/null | wc -l)
    if [ "$WORKTREES" -gt 0 ]; then
        echo "Worktrees still present ($WORKTREES):"
        ls -1 "$REPO_ROOT/.worktrees/"
        echo ""
        echo "To clean up:  git worktree list && git worktree prune"
        echo "Or remove all: rm -rf .worktrees/ && git worktree prune"
    fi
fi
