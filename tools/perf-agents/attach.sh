#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# attach.sh — Attach to perf-ai tmux sessions
#
# Usage:
#   ./tools/perf-agents/attach.sh              # list all perf-* sessions
#   ./tools/perf-agents/attach.sh server       # attach to perf-server
#   ./tools/perf-agents/attach.sh worker-1     # attach to perf-worker-1
#   ./tools/perf-agents/attach.sh 1            # shorthand for perf-worker-1
#
# Once attached:
#   Detach:            Ctrl+B, d
#   Session picker:    Ctrl+B, s
# =============================================================================

if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux not found. Install: sudo apt install tmux"
    exit 1
fi

attach_session() {
    local name="$1"
    if ! tmux has-session -t "$name" 2>/dev/null; then
        echo "No session '$name' found."
        echo ""
        echo "Active perf sessions:"
        tmux list-sessions -F "  #{session_name}" 2>/dev/null | grep "perf-\|W:" || echo "  (none)"
        echo ""
        echo "Start with: bash tools/perf-agents/start.sh"
        exit 1
    fi
    exec tmux attach-session -t "$name"
}

case "${1:-}" in
    ""|list|ls)
        echo "Active perf-ai sessions:"
        echo ""
        SESSIONS=$(tmux list-sessions -F "#{session_name}  (#{session_windows} windows, created #{session_created_string})" 2>/dev/null | grep "perf-\|W:" || true)
        if [ -z "$SESSIONS" ]; then
            echo "  (none)"
            echo ""
            echo "Start with: bash tools/perf-agents/start.sh"
        else
            echo "$SESSIONS" | while read -r line; do
                echo "  $line"
            done
            echo ""
            echo "Attach: bash tools/perf-agents/attach.sh <name>"
            echo "  e.g.  bash tools/perf-agents/attach.sh server"
            echo "  e.g.  bash tools/perf-agents/attach.sh worker-1"
            echo "  e.g.  bash tools/perf-agents/attach.sh 1  (shorthand)"
        fi
        ;;
    server)
        attach_session "perf-server"
        ;;
    worker-*)
        attach_session "perf-${1}"
        ;;
    [0-9]|[0-9][0-9])
        # Numeric shorthand: "1" → "perf-worker-1"
        attach_session "perf-worker-${1}"
        ;;
    -h|--help)
        echo "Usage: attach.sh [server|worker-N|N]"
        echo "  (no args)   List all perf-* sessions"
        echo "  server      Attach to perf-server"
        echo "  worker-N    Attach to perf-worker-N"
        echo "  N           Shorthand for perf-worker-N"
        ;;
    *)
        # Try as a session name directly (e.g. a W:EVM-1 renamed session)
        attach_session "$1"
        ;;
esac
