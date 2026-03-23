#!/usr/bin/env bash
set -euo pipefail

# Stop all dummy worker tmux sessions and clean up status files.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$SCRIPT_DIR/run"

SESSIONS=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^perf-dummy-" || true)

if [ -z "$SESSIONS" ]; then
    echo "No dummy sessions running."
else
    echo "$SESSIONS" | while read -r s; do
        tmux kill-session -t "$s" 2>/dev/null && echo "Killed $s" || true
    done
fi

# Clean up any leftover dummy status files
for f in "$RUN_DIR/status/"LR-DUMMY-*.json; do
    [ -f "$f" ] || continue
    rm -f "$f"
    echo "Removed $(basename "$f")"
done

echo "Done."
