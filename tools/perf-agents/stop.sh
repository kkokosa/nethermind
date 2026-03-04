#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# stop.sh — Stop the perf-ai agent system (zellij session)
#
# 1. Kills the "perf-agents" zellij session (SIGHUP → worker cleanup traps fire)
# 2. Removes stale status files, lock files, PID files
# 3. Optionally removes worktrees
#
# Usage:
#   ./tools/perf-agents/stop.sh          # kill session + cleanup
#   ./tools/perf-agents/stop.sh --force  # also remove all worktrees without prompting
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
SESSION_NAME="perf-agents"
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        -h|--help)
            echo "Usage: stop.sh [--force]"
            echo "  --force  Also remove all worktrees without prompting"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

echo "Stopping perf-ai agent system..."

# ── Kill zellij session ───────────────────────────────────────────────────────

if command -v zellij &>/dev/null; then
    if zellij list-sessions 2>/dev/null | grep -q "${SESSION_NAME}"; then
        zellij kill-session "$SESSION_NAME" 2>/dev/null || true
        zellij delete-session "$SESSION_NAME" 2>/dev/null || true
        echo "  Killed zellij session '$SESSION_NAME'"
    else
        echo "  No active '$SESSION_NAME' session found"
    fi
else
    echo "  zellij not found — skipping session kill"
fi

# ── Clean up runtime files ────────────────────────────────────────────────────

rm -f "$RUN_DIR/status/"*.json 2>/dev/null || true
rm -f "$RUN_DIR/benchmark.lock" 2>/dev/null || true
rm -f "$RUN_DIR/server.pid" 2>/dev/null || true
rm -f "$RUN_DIR/workers.pid" 2>/dev/null || true
rm -f "$RUN_DIR/perf-agents.kdl" 2>/dev/null || true
echo "  Cleaned up runtime files"

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
echo "All agents stopped."
