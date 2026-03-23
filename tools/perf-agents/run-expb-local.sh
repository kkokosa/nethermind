#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-expb-local.sh — Run EXPB real-payload replay locally via Docker
#
# Builds Docker images for candidate and baseline, runs expb execute-scenarios
# on each, and compares per-payload processing_ms.
#
# Usage:
#   ./tools/perf-agents/run-expb-local.sh <BRANCH> [BASELINE_BRANCH] [LOOP_RUN_ID]
#
# Environment:
#   EXPB_DELAY        — inter-payload delay in ms (default: 100)
#   EXPB_PAYLOAD_SET  — payload set name (default: halfpath)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BRANCH="${1:?Usage: run-expb-local.sh <BRANCH> [BASELINE_BRANCH] [LOOP_RUN_ID]}"
BASELINE_BRANCH="${2:-perf-ai/setup}"
LOOP_RUN_ID="${3:-expb-local}"
DELAY="${EXPB_DELAY:-100}"
PAYLOAD_SET="${EXPB_PAYLOAD_SET:-halfpath}"

RESULTS_DIR="$SCRIPT_DIR/run/expb-results/$LOOP_RUN_ID"

log() {
    echo "[expb] $*"
}

# Check prerequisites
for cmd in docker expb; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required. Run setup-expb.sh first."
        exit 1
    fi
done

if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# ── Build Docker images ──

build_image() {
    local ref="$1"
    local tag="$2"

    # Check if image already exists and is up to date
    local commit
    commit=$(git -C "$REPO_ROOT" rev-parse "$ref" 2>/dev/null || echo "unknown")
    local existing_label
    existing_label=$(docker inspect --format '{{index .Config.Labels "git.commit"}}' "$tag" 2>/dev/null || echo "")

    if [ "$existing_label" = "$commit" ] && [ "$commit" != "unknown" ]; then
        log "Image $tag already up to date (commit: ${commit:0:8})"
        return 0
    fi

    log "Building Docker image: $tag (ref: $ref, commit: ${commit:0:8})"
    docker build \
        --label "git.commit=$commit" \
        --label "git.ref=$ref" \
        --build-arg "GIT_REF=$ref" \
        -t "$tag" \
        "$REPO_ROOT" 2>&1 | tail -5

    log "Image $tag built successfully"
}

log "Building candidate image..."
build_image "$BRANCH" "nethermind-perf:candidate"

log "Building baseline image..."
build_image "$BASELINE_BRANCH" "nethermind-perf:baseline"

# ── Render config files ──

render_config() {
    local tag="$1"
    local scenario_name="$2"
    local output="$3"

    sed -e "s/<<DOCKER_TAG>>/$tag/g" \
        -e "s/<<DELAY>>/$DELAY/g" \
        -e "s/nethermind:/$scenario_name:/g" \
        "$SCRIPT_DIR/expb-local.yaml" > "$output"
}

CANDIDATE_CONFIG="$RESULTS_DIR/config-candidate.yaml"
BASELINE_CONFIG="$RESULTS_DIR/config-baseline.yaml"

render_config "candidate" "candidate" "$CANDIDATE_CONFIG"
render_config "baseline" "baseline" "$BASELINE_CONFIG"

# ── Run EXPB scenarios ──

run_expb() {
    local config="$1"
    local label="$2"
    local output_dir="$RESULTS_DIR/$label"
    mkdir -p "$output_dir"

    log "Running EXPB: $label"
    expb execute-scenarios \
        --config "$config" \
        --output-dir "$output_dir" \
        2>&1 | tee "$output_dir/expb.log" || {
        log "WARNING: EXPB $label run failed"
        return 1
    }
    log "EXPB $label complete"
}

run_expb "$BASELINE_CONFIG" "baseline" || true
run_expb "$CANDIDATE_CONFIG" "candidate" || true

# ── Compare results ──

log "Comparing results..."

python3 - "$RESULTS_DIR" << 'PYTHON_EOF'
import json
import os
import sys
from pathlib import Path

results_dir = Path(sys.argv[1])

def extract_metrics(label_dir):
    """Extract per-payload processing_ms from expb output."""
    metrics = {}
    for f in sorted(label_dir.glob("**/*.json")):
        try:
            data = json.loads(f.read_text())
            if isinstance(data, dict) and "processing_ms" in data:
                payload_id = data.get("payload", f.stem)
                metrics[payload_id] = data["processing_ms"]
            elif isinstance(data, list):
                for entry in data:
                    if isinstance(entry, dict) and "processing_ms" in entry:
                        payload_id = entry.get("payload", str(len(metrics)))
                        metrics[payload_id] = entry["processing_ms"]
        except (json.JSONDecodeError, OSError):
            pass
    return metrics

baseline_dir = results_dir / "baseline"
candidate_dir = results_dir / "candidate"

if not baseline_dir.exists() or not candidate_dir.exists():
    print("[expb] WARNING: Missing baseline or candidate results for comparison")
    result = {"status": "incomplete", "comparison": []}
    (results_dir / "expb-results.json").write_text(json.dumps(result, indent=2))
    sys.exit(0)

baseline_metrics = extract_metrics(baseline_dir)
candidate_metrics = extract_metrics(candidate_dir)

comparisons = []
for payload_id in sorted(set(baseline_metrics) | set(candidate_metrics)):
    b = baseline_metrics.get(payload_id)
    c = candidate_metrics.get(payload_id)
    delta_pct = None
    if b and c and b > 0:
        delta_pct = round((c - b) / b * 100, 2)
    comparisons.append({
        "payload": payload_id,
        "baseline_ms": b,
        "candidate_ms": c,
        "delta_pct": delta_pct,
    })

# Summary
if comparisons:
    deltas = [c["delta_pct"] for c in comparisons if c["delta_pct"] is not None]
    avg_delta = round(sum(deltas) / len(deltas), 2) if deltas else None
    print(f"\n[expb] EXPB Comparison Summary:")
    print(f"  Payloads compared: {len(deltas)}")
    print(f"  Avg delta: {avg_delta}%")
    for c in comparisons:
        d = c['delta_pct']
        marker = "  " if d is None else (" +" if d > 0 else " ")
        print(f"  {c['payload']}: {c['baseline_ms']}ms -> {c['candidate_ms']}ms ({marker}{d}%)")
else:
    avg_delta = None
    print("[expb] No comparable payloads found")

result = {
    "status": "complete",
    "avg_delta_pct": avg_delta,
    "payloads_compared": len([c for c in comparisons if c["delta_pct"] is not None]),
    "comparison": comparisons,
}
(results_dir / "expb-results.json").write_text(json.dumps(result, indent=2))
print(f"\n[expb] Results written to {results_dir / 'expb-results.json'}")
PYTHON_EOF

log "EXPB local benchmark complete. Results in: $RESULTS_DIR"
