#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-block-benchmark.sh — Run BlockProcessingBenchmark on candidate and baseline
#
# Runs the full-pipeline BlockProcessingBenchmark to validate that micro-level
# optimizations translate to real block processing improvement.
#
# Usage:
#   ./tools/perf-agents/run-block-benchmark.sh <LOOP_RUN_ID> <WORKTREE_DIR> [BASELINE_REF]
#
# BASELINE_REF defaults to perf-ai/setup
# Results are stored in ${LOOP_STATE_DIR}/candidate-bp-results/ and baseline-bp-results/
# =============================================================================

LOOP_RUN_ID="${1:?Usage: run-block-benchmark.sh <LOOP_RUN_ID> <WORKTREE_DIR> [BASELINE_REF]}"
WORKTREE_DIR="${2:?Usage: run-block-benchmark.sh <LOOP_RUN_ID> <WORKTREE_DIR> [BASELINE_REF]}"
BASELINE_REF="${3:-perf-ai/setup}"
LOOP_STATE_DIR="${LOOP_STATE_DIR:-loop-state/$LOOP_RUN_ID}"

BENCHMARK_PROJECT="src/Nethermind/Nethermind.Evm.Benchmark/"
BENCHMARK_FILTER="*BlockProcessingBenchmark*"

log() {
    echo "[block-bench] $*"
}

# ── Step 1: Benchmark candidate (current worktree) ──
log "Building and benchmarking CANDIDATE (BlockProcessingBenchmark)..."
cd "$WORKTREE_DIR"

mkdir -p "$LOOP_STATE_DIR/candidate-bp-results"

dotnet build -c Release "$BENCHMARK_PROJECT" --verbosity minimal

dotnet run -c Release --no-build --project "$BENCHMARK_PROJECT" \
    -- --filter "$BENCHMARK_FILTER" --exporters json 2>&1 || {
    log "WARNING: BlockProcessingBenchmark candidate run failed (non-fatal)"
    exit 0  # Non-fatal — micro benchmarks are the primary gate
}

# Copy results
if ls BenchmarkDotNet.Artifacts/results/*BlockProcessing*.json 1>/dev/null 2>&1; then
    cp BenchmarkDotNet.Artifacts/results/*BlockProcessing*.json \
        "$LOOP_STATE_DIR/candidate-bp-results/"
    log "Candidate BP results saved"
else
    log "WARNING: No BlockProcessingBenchmark JSON results found for candidate"
    exit 0
fi

# ── Step 2: Benchmark baseline ──
log "Creating temporary baseline worktree for BlockProcessingBenchmark..."
REPO_ROOT="$(git rev-parse --show-toplevel)/.."
BASELINE_WT="${REPO_ROOT}/.worktrees/${LOOP_RUN_ID,,}-bp-baseline"

# Clean up any stale baseline worktree
git worktree remove "$BASELINE_WT" --force 2>/dev/null || true

git worktree add "$BASELINE_WT" "$BASELINE_REF" 2>/dev/null || {
    log "WARNING: Could not create baseline worktree (non-fatal)"
    exit 0
}

cd "$BASELINE_WT"
mkdir -p "$WORKTREE_DIR/$LOOP_STATE_DIR/baseline-bp-results"

log "Building and benchmarking BASELINE (BlockProcessingBenchmark)..."
dotnet build -c Release "$BENCHMARK_PROJECT" --verbosity minimal 2>&1 || {
    log "WARNING: Baseline build failed (non-fatal)"
    cd "$WORKTREE_DIR"
    git worktree remove "$BASELINE_WT" --force 2>/dev/null || true
    exit 0
}

dotnet run -c Release --no-build --project "$BENCHMARK_PROJECT" \
    -- --filter "$BENCHMARK_FILTER" --exporters json 2>&1 || {
    log "WARNING: BlockProcessingBenchmark baseline run failed (non-fatal)"
    cd "$WORKTREE_DIR"
    git worktree remove "$BASELINE_WT" --force 2>/dev/null || true
    exit 0
}

# Copy baseline results
if ls BenchmarkDotNet.Artifacts/results/*BlockProcessing*.json 1>/dev/null 2>&1; then
    cp BenchmarkDotNet.Artifacts/results/*BlockProcessing*.json \
        "$WORKTREE_DIR/$LOOP_STATE_DIR/baseline-bp-results/"
    log "Baseline BP results saved"
else
    log "WARNING: No BlockProcessingBenchmark JSON results found for baseline"
fi

# ── Step 3: Cleanup ──
cd "$WORKTREE_DIR"
git worktree remove "$BASELINE_WT" --force 2>/dev/null || true

log "BlockProcessingBenchmark complete. Results in:"
log "  Candidate: $LOOP_STATE_DIR/candidate-bp-results/"
log "  Baseline:  $LOOP_STATE_DIR/baseline-bp-results/"
