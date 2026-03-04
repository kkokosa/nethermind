# Perf-AI Agent System (v3 — zellij)

## Changes from v2

1. **Zellij multiplexer** — all processes run as tabs in one zellij session.
   Attach/detach at will, watch Claude Code in real time, named tabs.
2. **WSL2-native** — no more PowerShell scripts or Windows quirks.
   Everything runs in `bash` under WSL2 with `python3` hardcoded.
3. **Orchestrator simplified** — `orchestrate.py` no longer spawns processes.
   It's now status-only + dry-run preview. Zellij owns process lifecycle.
4. **Tab naming** — workers rename their tab to `W:<TARGET_ID>` after claim.

## Changes from v1

1. **Dashboard pulls from API** — no JSON files on disk, no export script in the loop.
   Decision-server.py serves all data. Dashboard fetches via `useEffect` + polling.
2. **Workers pick their own targets** — each atomically claims the next-best target from SQLite.
3. **Git worktrees** — each worker gets its own filesystem via `git worktree add`.
   No working directory contention.
4. **Decision flow is complete** — Approve triggers branch push + PR creation +
   status update. Discard cleans up the worktree and marks done.

## Architecture

```
                              HUMAN
                     http://localhost:4040  │  terminal
                                ▼          ▼
              ┌──────────────────────────────────────────────┐
              │       zellij session "perf-agents"           │
              │                                              │
              │  Tab: [server]  [W:EVM-1]  [W:TRIE-1]  ...  │
              │   ↕ attach/detach (Ctrl+O,d)                 │
              │   ↕ navigate tabs (Alt+1..N)                 │
              └──────────────────────────────────────────────┘
                   │                │              │
              ┌────┘                │              └────┐
              ▼                     ▼                   ▼
┌──────────────────────┐    ┌────────────┐     ┌────────────┐
│decision-server.py    │    │ worker.sh  │     │ worker.sh  │
│(port 4040)           │    │  (claim)   │     │  (claim)   │
│                      │    │  EVM-1     │     │  TRIE-1    │
│ GET /api/loops       │    └─────┬──────┘     └─────┬──────┘
│ GET /api/workers     │          │                   │
│ POST /api/decision   │          ▼                   ▼
└──────────┬───────────┘    ┌────────────┐     ┌────────────┐
           │ reads/writes   │ Worktree   │     │ Worktree   │
           ▼                │ .wt/lr-001 │     │ .wt/lr-002 │
    ┌─────────────┐         └────────────┘     └────────────┘
    │   SQLite DB  │
    └─────────────┘
```

### Key commands

```bash
# Start (interactive — opens zellij session)
bash tools/perf-agents/start.sh --workers 2

# Detach from session (keeps everything running)
# Press: Ctrl+O, d

# Reattach
bash tools/perf-agents/attach.sh

# Check status (without attaching)
python3 tools/perf-agents/orchestrate.py --status

# Stop everything
bash tools/perf-agents/stop.sh
```

## Git Worktrees

### Why

Multiple Claude Code processes cannot share one working directory. If Worker 1
runs `git checkout master` to do a baseline benchmark, Worker 2's uncommitted
implementation files would be destroyed.

Git worktrees solve this: one `.git` repository, multiple working directories,
each on its own branch. Workers operate in complete isolation.

### Layout

```
nethermind/                         ← main repo (perf-ai/setup branch)
├── .git/
├── .worktrees/                     ← all agent worktrees (gitignored)
│   ├── lr-001/                     ← Worker 1's worktree
│   │   ├── src/Nethermind/...      ← full source tree on perf/evm-1/ai-...
│   │   └── loop-state/LR-001/     ← research brief, hypothesis, results
│   ├── lr-002/                     ← Worker 2's worktree
│   │   └── ...
│   └── lr-003/
│       └── ...
└── tools/perf-agents/
    └── run/status/*.json           ← live status (NOT in worktrees)
```

### Lifecycle

```bash
# Worker creates worktree + branch atomically
BRANCH="perf/${TARGET_ID,,}/ai-$(date +%Y%m%d-%H%M)"
WORKTREE_DIR=".worktrees/${LOOP_RUN_ID,,}"
git worktree add -b "$BRANCH" "$WORKTREE_DIR"

# Worker operates entirely inside its worktree
cd "$WORKTREE_DIR"
# ... all Claude Code sessions run here ...

# For baseline benchmarks, the worker does NOT checkout master.
# Instead, it creates a SECOND temporary worktree:
git worktree add ".worktrees/${LOOP_RUN_ID,,}-baseline" master
cd ".worktrees/${LOOP_RUN_ID,,}-baseline"
dotnet run -c Release --project src/Nethermind/Nethermind.Evm.Benchmark/ ...
# Copy results out, then remove:
git worktree remove ".worktrees/${LOOP_RUN_ID,,}-baseline"

# On completion (approved or discarded):
cd "$REPO_ROOT"
git worktree remove "$WORKTREE_DIR"
git branch -d "$BRANCH"  # only if discarded
```

### Baseline Benchmark Strategy

This is the tricky part. Each worker needs to benchmark both master (baseline)
and its branch (candidate). With worktrees, two options:

**Option A: Temporary baseline worktree** (recommended)
- Create a second worktree on master, build and benchmark there
- Copy JSON results to the main worktree's loop-state/
- Remove the baseline worktree
- Pro: clean isolation, no stashing
- Con: extra disk space (~350MB per worktree), build time

**Option B: Shared baseline cache**
- One designated "baseline" worktree that stays on master permanently
- Workers queue for benchmark lock, run baseline there, cache results
- Pro: baseline only built once, cached across workers
- Con: lock contention, stale baseline if master moves

We go with **Option A** for v1 (simpler). Add baseline caching later if build
time becomes a bottleneck.

## Worker Target Selection

Workers do NOT receive a target assignment. They claim one atomically.

### Claim protocol

```sql
-- Atomic claim: find highest-priority unclaimed target, insert loop_runs row
-- Uses SQLite's single-writer property for atomicity

BEGIN IMMEDIATE;  -- acquire write lock

-- Find best unclaimed target
SELECT target_id, difficulty, expected_impact
FROM optimization_targets_view
WHERE target_id NOT IN (
    SELECT target_id FROM loop_runs
    WHERE status NOT IN ('discarded', 'error')
)
ORDER BY priority_score DESC
LIMIT 1;

-- If found, insert the claim
INSERT INTO loop_runs (id, target_id, target_area, hypothesis, branch,
                       agent_type, difficulty, expected_impact, status)
VALUES (?, ?, ?, 'Claimed, research pending', ?, 'claude-code', ?, ?, 'research');

COMMIT;
```

Because SQLite serializes writes, two workers cannot claim the same target
even if they run simultaneously. The `BEGIN IMMEDIATE` acquires the write
lock upfront so the SELECT + INSERT are atomic.

### Target priority

Parsed from OPTIMIZATION-TARGETS.md at startup. Priority score = impact_weight * ease_weight:

| Impact | Weight |  | Difficulty | Weight |
|--------|--------|--|------------|--------|
| High   | 3      |  | S (easy)   | 3      |
| Med    | 2      |  | M          | 2      |
| Low    | 1      |  | L (hard)   | 1      |

So "High impact, S difficulty" = 9 (do first), "Low impact, L difficulty" = 1 (do last).

Workers can also be told to skip targets with `--exclude EVM-1,TRIE-2` or
forced to a specific target with `--target EVM-1` (bypasses claim protocol).

## Dashboard Data Flow

### Before (v1): static JSON files

```
SQLite → export_dashboard_data.py → JSON files → Vite bundles them → dashboard
```

Problems: stale data, requires re-export + rebuild or HMR hack, two processes.

### After (v2): API endpoints

```
SQLite → decision-server.py /api/* → fetch() from React → dashboard
```

The decision server reuses the same query logic from export_dashboard_data.py
but serves it as HTTP JSON responses. The dashboard polls every 5 seconds.

### API endpoints

| Endpoint | Returns | Used by |
|----------|---------|---------|
| `GET /api/loops` | All loop runs with comparison summaries | LoopRegistry, KPIs |
| `GET /api/progress` | Performance index time series | ProgressChart |
| `GET /api/benchmarks` | Key benchmark trends | BenchmarkTrends |
| `GET /api/agents` | Agent stats, area effectiveness, failures | Right column |
| `GET /api/pending` | Pending decisions with full context | PendingDecisions |
| `GET /api/workers` | Live worker status from status/*.json | LiveWorkerBar |
| `POST /api/decision` | Submit approve/discard | PendingDecisions |

### Dashboard data hook

```jsx
// hooks/useApiData.js
import { useState, useEffect, useCallback } from 'react';

export function useApiData(endpoint, pollInterval = 5000) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const fetchData = useCallback(async () => {
    try {
      const res = await fetch(endpoint);
      if (res.ok) {
        setData(await res.json());
        setError(null);
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, [endpoint]);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, pollInterval);
    return () => clearInterval(interval);
  }, [fetchData, pollInterval]);

  return { data, loading, error, refetch: fetchData };
}

// Usage in App.jsx:
const { data: loops } = useApiData('/api/loops');
const { data: progress } = useApiData('/api/progress');
const { data: benchmarks } = useApiData('/api/benchmarks');
const { data: agents } = useApiData('/api/agents');
```

### Graceful fallback

When running without decision-server (plain `npm run dev`), API calls fail.
The dashboard falls back to static JSON imports if API is unreachable:

```jsx
import FALLBACK_LOOPS from './data/loops.json';

const { data: loops, error } = useApiData('/api/loops');
const effectiveLoops = error ? FALLBACK_LOOPS : (loops || []);
```

This means the dashboard works in both modes:
- **With decision-server**: live data, pending decisions, worker status
- **Without**: static mock data for development/demo

## Decision Flow (POST /api/decision)

### On Approve (verdict = "improvement")

```
1. Update SQLite:
   - loop_runs.verdict = 'improvement'
   - loop_runs.status = 'done'
   - loop_runs.verdict_confidence = computed from comparisons

2. Push the branch (if not already pushed):
   cd .worktrees/<loop-run-id>
   git push origin <branch-name>

3. Create Pull Request (if gh CLI available):
   gh pr create --base perf-ai/setup --head <branch-name> \
     --title "perf(<target-id>): <summary>" \
     --body "<measurement report markdown>"

4. Return to dashboard:
   { "ok": true, "pr_url": "https://github.com/...", "status": "done" }

5. Worker (if still polling) sees verdict, cleans up worktree:
   git worktree remove .worktrees/<loop-run-id>
```

Note: the server does NOT auto-merge. It creates a PR. The human can then
review the PR on GitHub and merge manually (squash-merge). This gives a
second review opportunity and keeps the Git history clean.

### On Discard (verdict = "neutral" or "regression")

```
1. Update SQLite:
   - loop_runs.verdict = <verdict>
   - loop_runs.status = 'discarded'
   - loop_runs.verdict_notes = <human notes>

2. Return to dashboard:
   { "ok": true, "status": "discarded" }

3. Worker (if still polling) sees verdict, cleans up:
   git worktree remove .worktrees/<loop-run-id>
   git push origin --delete <branch-name>  # delete remote branch
```

### What if the worker already died?

The decision server handles this gracefully. Steps 1 (SQLite update) and 2-3
(push/PR) are done by the server itself, not the worker. The worker's only
post-decision role is worktree cleanup, which can also be done manually:

```bash
# Manual cleanup of all completed worktrees
git worktree list | grep '.worktrees/' | while read dir _ _; do
    git worktree remove "$dir" --force
done
```

## Orchestrator (Status-only)

The orchestrator no longer spawns processes — zellij owns the process lifecycle.
It provides status checks and dry-run previews:

```bash
# Show system status (zellij session, workers, recent loops)
python3 orchestrate.py --status

# Preview which targets would be claimed
python3 orchestrate.py --dry-run --workers 3

# Preview with exclusions
python3 orchestrate.py --dry-run --workers 3 --exclude "EVM-1,TRIE-2"
```

## Schema Changes

Add to the status CHECK constraint:

```sql
CHECK (status IN ('research','implementing','benchmarking',
                  'pending_decision','iterating',
                  'done','discarded','error'))
```

Add a `worktree_path` column to loop_runs:

```sql
ALTER TABLE loop_runs ADD COLUMN worktree_path TEXT;
```

## Directory Structure

```
tools/perf-agents/
├── start.sh                    # Generate KDL layout, launch zellij session
├── stop.sh                     # Kill zellij session, cleanup
├── attach.sh                   # Reattach to session (or list sessions)
├── stop-legacy.sh              # Non-zellij fallback (PID-based stop)
├── orchestrate.py              # Status + dry-run preview (no longer spawns)
├── worker.sh                   # Generic worker (claims target, runs loop)
├── claim_target.py             # Atomic target claim from SQLite
├── decision-server.py          # HTTP server (dashboard + API + decision)
├── PROMPTS/
│   ├── research.md             # Phase 1-2 prompt
│   └── implement.md            # Phase 3-5 prompt
├── run/                        # Runtime (gitignored)
│   ├── perf-agents.kdl         # Generated zellij layout
│   ├── benchmark.lock
│   ├── logs/*.log
│   └── status/*.json
└── AGENT-SYSTEM.md             # This file

.worktrees/                     # Worktrees (gitignored)
├── lr-001/                     # Worker 1
├── lr-002/                     # Worker 2
└── lr-001-baseline/            # Temporary baseline worktree
```

## Implementation Priority

| Step | What | Effort |
|------|------|--------|
| 1 | Schema migration (add statuses + worktree_path) | S |
| 2 | claim_target.py (atomic target claim) | S |
| 3 | worker.sh v2 (worktrees + claim protocol) | M |
| 4 | decision-server.py v2 (all /api/* endpoints, merge flow) | M |
| 5 | Dashboard: useApiData hook + App.jsx refactor | M |
| 6 | Dashboard: PendingDecisions component | M |
| 7 | orchestrate.py v2 (just spawn N workers) | S |
| 8 | start.sh / stop_all.sh | S |
