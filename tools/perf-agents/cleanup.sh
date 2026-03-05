#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# cleanup.sh — Clean up stale state from crashed/killed workers
#
# Handles:
#   1. Stale status files (dead PIDs in run/status/*.json)
#   2. Orphaned worktrees (no running worker)
#   3. Stale DB entries (mark as error so targets can be re-claimed)
#   4. Benchmark lock file
#   5. Windows-side ghost processes on dashboard port
#
# Usage:
#   ./tools/perf-agents/cleanup.sh              # interactive (asks before removing worktrees)
#   ./tools/perf-agents/cleanup.sh --force      # remove everything without prompting
#   ./tools/perf-agents/cleanup.sh --dry-run    # show what would be cleaned, don't touch anything
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
DB_PATH="$REPO_ROOT/tools/perf-dashboard/db/perf.db"
WORKTREE_ROOT="$REPO_ROOT/.worktrees"

FORCE=false
DRY_RUN=false
RESET_DB=false
PORT=4040

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)    FORCE=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --reset-db) RESET_DB=true; shift ;;
        --port)     PORT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: cleanup.sh [--force] [--dry-run] [--reset-db] [--port N]"
            echo "  --force     Remove everything without prompting"
            echo "  --dry-run   Show what would be cleaned, don't touch anything"
            echo "  --reset-db  Wipe all loop_runs, comparisons, and benchmark_results"
            echo "  --port N    Dashboard port to check for ghost processes (default: 4040)"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

action() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        echo "  $*"
    fi
}

echo "Perf-AI cleanup"
echo ""

FOUND_ISSUES=false

# ── 1. Stale status files ────────────────────────────────────────────────────

STALE_STATUS=()
if [ -d "$RUN_DIR/status" ]; then
    for f in "$RUN_DIR/status/"*.json; do
        [ -f "$f" ] || continue
        pid=$(python3 -c "import json; print(json.load(open('$f')).get('pid',0))" 2>/dev/null || echo 0)
        if [ "$pid" = "0" ] || ! kill -0 "$pid" 2>/dev/null; then
            STALE_STATUS+=("$f")
        fi
    done
fi

if [ ${#STALE_STATUS[@]} -gt 0 ]; then
    FOUND_ISSUES=true
    echo "Stale status files (${#STALE_STATUS[@]}):"
    for f in "${STALE_STATUS[@]}"; do
        name=$(basename "$f")
        action "Remove $name"
        $DRY_RUN || rm -f "$f"
    done
    echo ""
fi

# ── 2. Benchmark lock ────────────────────────────────────────────────────────

if [ -f "$RUN_DIR/benchmark.lock" ]; then
    LOCK_CONTENT=$(cat "$RUN_DIR/benchmark.lock" 2>/dev/null || echo "")
    LOCK_PID=$(echo "$LOCK_CONTENT" | grep -oP 'PID \K[0-9]+' || echo "0")
    if [ "$LOCK_PID" = "0" ] || ! kill -0 "$LOCK_PID" 2>/dev/null; then
        FOUND_ISSUES=true
        echo "Stale benchmark lock:"
        action "Remove benchmark.lock (was: $LOCK_CONTENT)"
        $DRY_RUN || rm -f "$RUN_DIR/benchmark.lock"
        echo ""
    fi
fi

# ── 3. Stale DB entries ──────────────────────────────────────────────────────

if [ -f "$DB_PATH" ]; then
    STALE_RUNS=$(sqlite3 "$DB_PATH" \
        "SELECT id, target_id, status FROM loop_runs WHERE status IN ('research','implementing','benchmarking','iterating') ORDER BY id" \
        2>/dev/null || echo "")

    if [ -n "$STALE_RUNS" ]; then
        FOUND_ISSUES=true
        echo "Stale DB entries (active status but no running worker):"
        while IFS='|' read -r run_id target_id status; do
            # Check if any worker is actually handling this run
            STATUS_FILE="$RUN_DIR/status/${run_id}.json"
            ALIVE=false
            if [ -f "$STATUS_FILE" ]; then
                pid=$(python3 -c "import json; print(json.load(open('$STATUS_FILE')).get('pid',0))" 2>/dev/null || echo 0)
                if [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
                    ALIVE=true
                fi
            fi

            if ! $ALIVE; then
                action "Mark $run_id ($target_id, status=$status) as error"
                $DRY_RUN || sqlite3 "$DB_PATH" \
                    "UPDATE loop_runs SET status='error', approach=COALESCE(approach,'') || ' [cleaned up: worker died]', updated_at=datetime('now') WHERE id='$run_id'"
            fi
        done <<< "$STALE_RUNS"
        echo ""
    fi
fi

# ── 4. Orphaned worktrees ────────────────────────────────────────────────────

if [ -d "$WORKTREE_ROOT" ]; then
    ORPHANS=()
    for wt in "$WORKTREE_ROOT"/*/; do
        [ -d "$wt" ] || continue
        wt_name=$(basename "$wt")
        # Check if any worker is using this worktree
        ALIVE=false
        for sf in "$RUN_DIR/status/"*.json; do
            [ -f "$sf" ] || continue
            wt_path=$(python3 -c "import json; print(json.load(open('$sf')).get('worktree',''))" 2>/dev/null || echo "")
            pid=$(python3 -c "import json; print(json.load(open('$sf')).get('pid',0))" 2>/dev/null || echo 0)
            if [ "$wt_path" = "$wt" ] || [[ "$wt_path" == *"$wt_name"* ]]; then
                if [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
                    ALIVE=true
                    break
                fi
            fi
        done

        if ! $ALIVE; then
            ORPHANS+=("$wt_name")
        fi
    done

    if [ ${#ORPHANS[@]} -gt 0 ]; then
        FOUND_ISSUES=true
        echo "Orphaned worktrees (${#ORPHANS[@]}):"
        for wt_name in "${ORPHANS[@]}"; do
            echo "  $wt_name"
        done

        REMOVE=false
        if $DRY_RUN; then
            echo "  [dry-run] Would remove ${#ORPHANS[@]} worktree(s)"
        elif $FORCE; then
            REMOVE=true
        else
            echo ""
            read -rp "  Remove orphaned worktrees? [y/N] " answer
            case "$answer" in
                [yY]|[yY][eE][sS]) REMOVE=true ;;
            esac
        fi

        if $REMOVE && ! $DRY_RUN; then
            for wt_name in "${ORPHANS[@]}"; do
                wt="$WORKTREE_ROOT/$wt_name"
                git -C "$REPO_ROOT" worktree remove "$wt" --force 2>/dev/null || {
                    echo "  Warning: git worktree remove failed for $wt_name, removing directory"
                    rm -rf "$wt"
                }
                echo "  Removed worktree: $wt_name"
            done
            git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
        fi
        echo ""
    fi
fi

# ── 5. Windows ghost processes on dashboard port ──────────────────────────────

if command -v netstat.exe &>/dev/null; then
    GHOST_LINE=$(netstat.exe -ano 2>/dev/null | grep ":${PORT}.*LISTENING" | head -1 || true)
    if [ -n "$GHOST_LINE" ]; then
        GHOST_PID=$(echo "$GHOST_LINE" | awk '{print $NF}')
        GHOST_NAME=$(tasklist.exe //FI "PID eq $GHOST_PID" //FO CSV //NH 2>/dev/null | head -1 | cut -d'"' -f2 || echo "unknown")

        # Only kill if it's a python process (avoid killing unrelated services)
        if [[ "$GHOST_NAME" == *python* ]]; then
            FOUND_ISSUES=true
            echo "Windows ghost process on port $PORT:"
            action "Kill $GHOST_NAME (PID $GHOST_PID)"
            if ! $DRY_RUN; then
                taskkill.exe //PID "$GHOST_PID" //F 2>/dev/null || echo "  Failed to kill PID $GHOST_PID"
            fi
            echo ""
        fi
    fi
fi

# ── 6. Reset DB (optional) ────────────────────────────────────────────────────

if $RESET_DB && [ -f "$DB_PATH" ]; then
    FOUND_ISSUES=true
    ROW_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM loop_runs" 2>/dev/null || echo "0")
    echo "Reset database ($ROW_COUNT loop_runs):"

    WIPE=false
    if $DRY_RUN; then
        echo "  [dry-run] Would delete all loop_runs, comparisons, benchmark_results"
    elif $FORCE; then
        WIPE=true
    else
        read -rp "  Wipe all loop_runs, comparisons, and benchmark_results? [y/N] " answer
        case "$answer" in
            [yY]|[yY][eE][sS]) WIPE=true ;;
        esac
    fi

    if $WIPE && ! $DRY_RUN; then
        sqlite3 "$DB_PATH" "DELETE FROM comparisons; DELETE FROM benchmark_results; DELETE FROM loop_runs;"
        echo "  Wiped loop_runs, comparisons, benchmark_results"
    fi
    echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────────

if ! $FOUND_ISSUES; then
    echo "Nothing to clean up. All clear."
fi

echo ""
echo "Done."
