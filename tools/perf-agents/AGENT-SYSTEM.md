# Perf-AI Agent System (v4 — tmux + sandbox)

## Changes from v3

1. **tmux sessions** — server and each worker run in independent tmux sessions.
   Killing a worker doesn't affect the server or other workers.
2. **Bubblewrap sandboxing** — workers are restricted to their worktree via
   `.claude/settings.json` filesystem/network rules.
3. **No `--dangerously-skip-permissions`** — sandbox + `autoAllowBashIfSandboxed`
   + explicit permission allow-list handles it.
4. **Granular start/stop** — add or remove individual workers on the fly.

## Changes from v2

1. **Dashboard pulls from API** — no JSON files on disk, no export script in the loop.
   Decision-server.py serves all data. Dashboard fetches via `useEffect` + polling.
2. **Workers pick their own targets** — each atomically claims the next-best target from SQLite.
3. **Git worktrees** — each worker gets its own filesystem via `git worktree add`.
   No working directory contention.
4. **Decision flow is complete** — Approve triggers branch push + PR creation +
   status update. Discard cleans up the worktree and marks done.

## Architecture

```
tmux sessions (independent, can kill/restart individually):

  perf-server       →  decision-server.py (port 4040)
  perf-worker-1     →  worker.sh → claims EVM-1, renames session to W:EVM-1
  perf-worker-2     →  worker.sh → claims TRIE-1, renames session to W:TRIE-1
  ...

                              HUMAN
                     http://localhost:4040  │  terminal
                                |          |
              ┌─────────────────┼──────────┤
              │                 │          │
              ▼                 ▼          ▼
┌──────────────────────┐  ┌────────────┐  ┌────────────┐
│ tmux: perf-server    │  │ tmux:      │  │ tmux:      │
│ decision-server.py   │  │ W:EVM-1    │  │ W:TRIE-1   │
│ (port 4040)          │  │ worker.sh  │  │ worker.sh  │
│                      │  └─────┬──────┘  └─────┬──────┘
│ GET /api/loops       │        │               │
│ GET /api/workers     │        ▼               ▼
│ POST /api/decision   │  ┌────────────┐  ┌────────────┐
└──────────┬───────────┘  │ Worktree   │  │ Worktree   │
           │ reads/writes │ .wt/lr-001 │  │ .wt/lr-002 │
           ▼              └────────────┘  └────────────┘
    ┌─────────────┐
    │   SQLite DB  │
    └─────────────┘
```

### Key commands

```bash
# Start server + 2 workers (default)
bash tools/perf-agents/start.sh --workers 2

# Start server only
bash tools/perf-agents/start.sh --server-only

# Add one more worker to running fleet
bash tools/perf-agents/start.sh --worker

# Add a worker for a specific target
bash tools/perf-agents/start.sh --worker --target EVM-1

# List all active sessions
bash tools/perf-agents/attach.sh

# Attach to server or worker
bash tools/perf-agents/attach.sh server
bash tools/perf-agents/attach.sh worker-1
bash tools/perf-agents/attach.sh 1           # shorthand

# Detach from session (keeps running)
# Press: Ctrl+B, d

# Session picker (switch between sessions)
# Press: Ctrl+B, s

# Check status (without attaching)
python3 tools/perf-agents/orchestrate.py --status

# Stop everything
bash tools/perf-agents/stop.sh

# Stop just the server
bash tools/perf-agents/stop.sh --server-only

# Stop just workers (server stays up)
bash tools/perf-agents/stop.sh --workers-only

# Stop one specific worker
bash tools/perf-agents/stop.sh --worker 2

# Stop everything + remove worktrees
bash tools/perf-agents/stop.sh --force

# Clean up stale state from crashed workers
bash tools/perf-agents/cleanup.sh

# Preview what cleanup would do
bash tools/perf-agents/cleanup.sh --dry-run

# Force cleanup (no prompts)
bash tools/perf-agents/cleanup.sh --force
```

### Why tmux over zellij?

- **Independent sessions**: each component has its own session. Killing a worker
  doesn't take down the server or other workers.
- **Headless-friendly**: tmux is standard in CI/SSH environments.
- **Claude Code integration**: tmux has native support in Claude Code agent teams.
- **Hot add/remove**: add workers to a running system without restarting anything.

## Bubblewrap Sandboxing

Workers are sandboxed via `.claude/settings.json` (checked into repo):

```json
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "allowWrite": [".", "//tmp/perf-agents"],
      "denyWrite": ["//etc", "//usr/bin", "//usr/local/bin"],
      "denyRead": ["~/.ssh", "~/.aws", "~/.gnupg"]
    },
    "network": {
      "allowedDomains": ["github.com", "api.github.com", "*.nuget.org", "api.anthropic.com"]
    }
  }
}
```

**Key properties:**
- `allowWrite: ["."]` — workers can only write within the project directory (their worktree)
- `denyRead` — sensitive directories are inaccessible
- `allowedDomains` — network restricted to GitHub, NuGet, and Anthropic API
- `autoAllowBashIfSandboxed` — bash commands run without interactive prompts inside sandbox

**Prerequisites:**
```bash
sudo apt install bubblewrap socat
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

Each worker needs to benchmark both master (baseline) and its branch (candidate).

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

The decision server serves data from SQLite as HTTP JSON responses.
The dashboard polls every 5 seconds.

### Graceful fallback

When running without decision-server (plain `npm run dev`), API calls fail.
The dashboard falls back to static JSON imports if API is unreachable.

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

## Orchestrator (Status-only)

The orchestrator no longer spawns processes — tmux owns the process lifecycle.
It provides status checks and dry-run previews:

```bash
# Show system status (tmux sessions, workers, recent loops)
python3 orchestrate.py --status

# Preview which targets would be claimed
python3 orchestrate.py --dry-run --workers 3

# Preview with exclusions
python3 orchestrate.py --dry-run --workers 3 --exclude "EVM-1,TRIE-2"
```

## Validation Layers

The agent loop has three validation layers beyond microbenchmarks:

### Layer 1: Correctness Gate (automated, blocks progress)

After implementation, `run-correctness-check.sh` runs targeted unit tests for the
affected area (EVM -> Nethermind.Evm.Test, TRIE -> Nethermind.Trie.Test, etc.).
Added as backpressure gate #4 in `implement.md`. If tests fail, the attempt is
marked as error and skipped.

### Layer 2: Block Processing Benchmark (automated, alongside micro-BDN)

`BlockProcessingBenchmark` (9 scenarios: EmptyBlock through MixedBlock) runs on
both baseline and candidate as part of the implement session. Results flow into
the comparisons table and are displayed separately in pending decisions.
This validates that micro-level gains translate to real block processing speedup.

### Layer 3: EXPB Real Payload Replay (human-triggered)

For promising changes, humans can trigger local EXPB via the dashboard
("Run EXPB" button or `POST /api/trigger-expb`). This builds Docker images
for baseline and candidate, then replays real mainnet blocks through the
full client via Engine API. Results show per-payload processing_ms comparison.

Scripts:
- `setup-expb.sh` — one-time setup (installs expb via uv)
- `run-expb-local.sh` — runs EXPB for a branch vs baseline
- `expb-local.yaml` — config template for local runs

API endpoints:
- `POST /api/trigger-expb` — start EXPB run (body: `{"loopRunId": "LR-001"}`)
- `GET /api/expb-status/<id>` — poll EXPB run status and results

## Directory Structure

```
tools/perf-agents/
├── start.sh                    # Launch tmux sessions (server + workers)
├── stop.sh                     # Kill tmux sessions with granular control
├── attach.sh                   # Attach to specific tmux session
├── cleanup.sh                  # Clean stale status, worktrees, DB entries, ghost processes
├── orchestrate.py              # Status + dry-run preview (no longer spawns)
├── worker.sh                   # Generic worker (claims target, runs loop)
├── claim_target.py             # Atomic target claim from SQLite
├── decision-server.py          # HTTP server (dashboard + API + decision)
├── run-correctness-check.sh    # Layer 1: targeted unit tests per area
├── run-block-benchmark.sh      # Layer 2: BlockProcessingBenchmark wrapper
├── setup-expb.sh               # Layer 3: one-time EXPB setup
├── run-expb-local.sh           # Layer 3: local EXPB execution
├── expb-local.yaml             # Layer 3: EXPB config template
├── PROMPTS/
│   ├── research.md             # Phase 1-2 prompt
│   └── implement.md            # Phase 3-5 prompt (includes correctness + BP gates)
├── run/                        # Runtime (gitignored)
│   ├── benchmark.lock
│   ├── logs/*.log
│   ├── status/*.json
│   └── expb-results/           # EXPB run outputs
└── AGENT-SYSTEM.md             # This file

.claude/
└── settings.json               # Sandbox config (checked in, applies to workers)

.worktrees/                     # Worktrees (gitignored)
├── lr-001/                     # Worker 1
├── lr-002/                     # Worker 2
└── lr-001-baseline/            # Temporary baseline worktree
```
