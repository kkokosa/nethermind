# Task: Implement Perf-AI Agent System v2

## Architecture summary

Read `tools/perf-agents/AGENT-SYSTEM.md` for full design. Key changes from v1:

1. **Dashboard pulls from API** — decision-server.py serves all /api/* endpoints,
   dashboard fetches via `useApiData` hook with polling. Static JSON is fallback only.
2. **Workers claim targets** — each worker atomically claims the next-best target
   from SQLite (BEGIN IMMEDIATE transaction). No central assignment.
3. **Git worktrees** — each worker operates in its own `.worktrees/<lr-id>/` directory.
   Baseline benchmarks use a temporary second worktree.
4. **Decision API does the merge** — POST /api/decision pushes branch, creates PR
   via `gh`, and cleans up the worktree. Worker just waits for verdict.

## Files to install

Copy all files from this package to the repo:

| Source | Destination | Notes |
|--------|-------------|-------|
| `AGENT-SYSTEM-v2.md` | `tools/perf-agents/AGENT-SYSTEM.md` | |
| `claim_target.py` | `tools/perf-agents/claim_target.py` | |
| `worker.sh` | `tools/perf-agents/worker.sh` | `chmod +x` |
| `orchestrate.py` | `tools/perf-agents/orchestrate.py` | |
| `decision-server.py` | `tools/perf-agents/decision-server.py` | |
| `start.sh` | `tools/perf-agents/start.sh` | `chmod +x` |
| `stop_all.sh` | `tools/perf-agents/stop_all.sh` | `chmod +x` |
| `PROMPTS/research.md` | `tools/perf-agents/PROMPTS/research.md` | |
| `PROMPTS/implement.md` | `tools/perf-agents/PROMPTS/implement.md` | |
| `migrate_schema.sql` | `tools/perf-dashboard/migrate_schema.sql` | |
| `useApiData.js` | `tools/perf-dashboard/dashboard/src/hooks/useApiData.js` | new dir |
| `App.jsx` | `tools/perf-dashboard/dashboard/src/App.jsx` | replaces existing |
| `PendingDecisions.jsx` | `tools/perf-dashboard/dashboard/src/components/PendingDecisions.jsx` | |

## Step-by-step implementation

### Step 1: Directory structure

```bash
mkdir -p tools/perf-agents/{PROMPTS,run/{logs,status}}
mkdir -p tools/perf-dashboard/dashboard/src/hooks
mkdir -p .worktrees

# Gitignore runtime dirs
echo "run/" >> tools/perf-agents/.gitignore
grep -q "^\.worktrees/" .gitignore || echo ".worktrees/" >> .gitignore
```

### Step 2: Schema migration

```bash
# If DB already exists, run migration:
sqlite3 tools/perf-dashboard/db/perf.db < tools/perf-dashboard/migrate_schema.sql

# If DB doesn't exist yet, update schema.sql to include the new statuses
# and worktree_path column, then run init_db.py
```

Verify:
```bash
sqlite3 tools/perf-dashboard/db/perf.db ".schema loop_runs" | grep pending_decision
# Should show: 'pending_decision','iterating' in the CHECK constraint
sqlite3 tools/perf-dashboard/db/perf.db ".schema loop_runs" | grep worktree_path
# Should show: worktree_path TEXT
```

### Step 3: Install agent scripts

Copy all Python/shell files. Make shell scripts executable.

### Step 4: Install dashboard changes

1. Create `src/hooks/useApiData.js`
2. Replace `src/App.jsx` with new version
3. Add `src/components/PendingDecisions.jsx`

The new App.jsx:
- Imports `useLiveData` and `useApiData` from hooks
- Uses `useLiveData('/api/loops', FALLBACK_LOOPS)` instead of direct JSON import
- Adds `<PendingDecisions />` between header and KPI bar
- Shows "LIVE" indicator when decision server is connected

### Step 5: Update CLAUDE.md

Add to CLAUDE.md:

```markdown
## Agent System

Autonomous optimization agents in `tools/perf-agents/`:
- `start.sh --workers N` — launch N workers + dashboard
- `stop_all.sh` — kill everything
- `orchestrate.py --status` — check system state
- Dashboard: http://localhost:4040 (when running)

Each worker: claims a target → creates git worktree → researches →
implements → benchmarks → waits for human approval via dashboard.

Key files:
- `AGENT-SYSTEM.md` — full architecture
- `claim_target.py` — atomic target claim from SQLite
- `worker.sh` — per-target loop (wraps Claude Code)
- `decision-server.py` — dashboard HTTP server + decision API
- `PROMPTS/` — Claude Code prompt templates
```

### Step 6: Verify end-to-end

```bash
# 1. Init DB
python tools/perf-dashboard/scripts/init_db.py

# 2. Run schema migration
sqlite3 tools/perf-dashboard/db/perf.db < tools/perf-dashboard/migrate_schema.sql

# 3. Test claim
python tools/perf-agents/claim_target.py --dry-run
# Should output JSON with a target_id and loop_run_id

# 4. Test orchestrator dry run
python tools/perf-agents/orchestrate.py --dry-run --workers 3
# Should list 3 targets that would be claimed

# 5. Start dashboard only
python tools/perf-agents/decision-server.py --port 4040 &

# 6. Test API endpoints
curl -s http://localhost:4040/api/loops | python -m json.tool | head -5
curl -s http://localhost:4040/api/pending | python -m json.tool
curl -s http://localhost:4040/api/workers | python -m json.tool

# 7. Register a test loop and mark pending
python tools/perf-dashboard/scripts/register_loop.py \
  --target-id EVM-1 --hypothesis "Test" --branch "test/branch" \
  --agent claude-code --difficulty S --expected-impact high

sqlite3 tools/perf-dashboard/db/perf.db \
  "UPDATE loop_runs SET status='pending_decision' WHERE target_id='EVM-1'"

# 8. Verify pending appears in API
curl -s http://localhost:4040/api/pending | python -m json.tool

# 9. Test decision submission
curl -X POST http://localhost:4040/api/decision \
  -H 'Content-Type: application/json' \
  -d '{"loopRunId":"LR-001","verdict":"improvement","notes":"Test"}'

# 10. Verify status updated
curl -s http://localhost:4040/api/loops | python -m json.tool | head -5

# 11. Clean up
kill %1  # stop server
```

### Step 7: Full system test (with one real worker)

```bash
# This actually runs Claude Code — requires claude CLI installed
bash tools/perf-agents/start.sh --target EVM-1

# Monitor
python tools/perf-agents/orchestrate.py --status
tail -f tools/perf-agents/run/logs/*.log

# When pending_decision appears, open http://localhost:4040
# Click Approve or Discard

# Stop
bash tools/perf-agents/stop_all.sh
```

## Verification checklist

- [ ] `claim_target.py --dry-run` returns JSON with target + loop ID
- [ ] Two simultaneous claims get different targets (test with `&`)
- [ ] `orchestrate.py --dry-run --workers 5` lists 5 distinct targets
- [ ] `decision-server.py` starts, all /api/* return valid JSON
- [ ] Dashboard loads with "LIVE" indicator when server running
- [ ] Dashboard falls back to static JSON when server not running
- [ ] PendingDecisions shows loops with status=pending_decision
- [ ] POST /api/decision updates SQLite status correctly
- [ ] POST /api/decision with verdict=improvement attempts `gh pr create`
- [ ] POST /api/decision with verdict=neutral cleans up remote branch
- [ ] worker.sh creates worktree in .worktrees/
- [ ] worker.sh creates baseline worktree for benchmarks
- [ ] worker.sh cleans up worktrees after completion
- [ ] stop_all.sh kills server + workers, reports leftover worktrees
- [ ] Schema migration adds pending_decision, iterating, worktree_path
