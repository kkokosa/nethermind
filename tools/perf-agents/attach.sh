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

# Session name filter: matches perf-*, W:*, W_* (tmux converts : to _)
SESSION_FILTER="perf-\|^W[_:]"

attach_session() {
    local name="$1"
    if ! tmux has-session -t "$name" 2>/dev/null; then
        echo "No session '$name' found."
        echo ""
        echo "Active perf sessions:"
        tmux list-sessions -F "  #{session_name}" 2>/dev/null | grep "$SESSION_FILTER" || echo "  (none)"
        echo ""
        echo "Start with: bash tools/perf-agents/start.sh"
        exit 1
    fi
    exec tmux attach-session -t "$name"
}

# Find a worker session by target name (e.g., "EVM-1" matches "W_EVM-1")
find_worker_session() {
    local target="$1"
    # Try exact matches: W:TARGET, W_TARGET, perf-worker-N
    for prefix in "W:" "W_" "perf-worker-"; do
        if tmux has-session -t "${prefix}${target}" 2>/dev/null; then
            echo "${prefix}${target}"
            return 0
        fi
    done
    # Try case-insensitive partial match
    tmux list-sessions -F "#{session_name}" 2>/dev/null \
        | grep -i "$target" \
        | grep "$SESSION_FILTER" \
        | head -1
}

case "${1:-}" in
    ""|list|ls)
        echo "Active perf-ai sessions:"
        echo ""
        SESSIONS=$(tmux list-sessions -F "#{session_name}  (#{session_windows} windows, created #{session_created_string})" 2>/dev/null | grep "$SESSION_FILTER" || true)
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
            echo "  e.g.  bash tools/perf-agents/attach.sh EVM-1"
            echo "  e.g.  bash tools/perf-agents/attach.sh 1  (shorthand for perf-worker-1)"
        fi
        ;;
    server)
        attach_session "perf-server"
        ;;
    researcher)
        attach_session "perf-researcher"
        ;;
    worker-*)
        attach_session "perf-${1}"
        ;;
    [0-9]|[0-9][0-9])
        # Numeric shorthand: "1" → "perf-worker-1"
        attach_session "perf-worker-${1}"
        ;;
    -h|--help)
        echo "Usage: attach.sh [server|worker-N|N|TARGET]"
        echo "  (no args)   List all perf-* / W_* sessions"
        echo "  server      Attach to perf-server"
        echo "  worker-N    Attach to perf-worker-N"
        echo "  N           Shorthand for perf-worker-N"
        echo "  TARGET      Match by target name (e.g. EVM-1, TRIE-2)"
        ;;
    *)
        # Try direct name first, then search by target
        if tmux has-session -t "$1" 2>/dev/null; then
            exec tmux attach-session -t "$1"
        fi
        MATCH=$(find_worker_session "$1")
        if [ -n "$MATCH" ]; then
            exec tmux attach-session -t "$MATCH"
        fi
        echo "No session matching '$1' found."
        echo ""
        echo "Active perf sessions:"
        tmux list-sessions -F "  #{session_name}" 2>/dev/null | grep "$SESSION_FILTER" || echo "  (none)"
        exit 1
        ;;
esac
