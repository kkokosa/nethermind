#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# attach.sh — Reattach to the perf-agents zellij session
#
# Usage:
#   ./tools/perf-agents/attach.sh          # attach to perf-agents session
#   ./tools/perf-agents/attach.sh list      # list all zellij sessions
#   ./tools/perf-agents/attach.sh ls        # same as list
#
# Once attached, navigate tabs with Alt+<number>:
#   Alt+1 = server, Alt+2 = worker-1, Alt+3 = worker-2, ...
# Detach without killing: Ctrl+O, d
# =============================================================================

SESSION_NAME="perf-agents"

if ! command -v zellij &>/dev/null; then
    echo "ERROR: zellij not found. Install: cargo install zellij"
    exit 1
fi

case "${1:-}" in
    list|ls)
        echo "Active zellij sessions:"
        zellij list-sessions 2>/dev/null || echo "  (none)"
        ;;
    ""|attach)
        if ! zellij list-sessions 2>/dev/null | grep -q "^${SESSION_NAME}"; then
            echo "No active '$SESSION_NAME' session."
            echo "Start one with: bash tools/perf-agents/start.sh"
            exit 1
        fi
        exec zellij attach "$SESSION_NAME"
        ;;
    -h|--help)
        echo "Usage: attach.sh [list|ls]"
        echo "  (no args)  Attach to perf-agents session"
        echo "  list/ls    List all zellij sessions"
        ;;
    *)
        echo "Unknown: $1"
        echo "Usage: attach.sh [list|ls]"
        exit 1
        ;;
esac
