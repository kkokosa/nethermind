#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-expb.sh — One-time setup for local EXPB (execution payload benchmarks)
#
# Installs expb via uv and creates the local config template.
# Prerequisites: uv, docker
#
# Usage:
#   ./tools/perf-agents/setup-expb.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
    echo "[setup-expb] $*"
}

# Check prerequisites
for cmd in uv docker; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not found on PATH"
        exit 1
    fi
done

# Check Docker is running
if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running"
    exit 1
fi

# Install expb
log "Installing expb via uv..."
uv tool install --force --from "git+https://github.com/NethermindEth/execution-payloads-benchmarks" expb

# Verify
if command -v expb &>/dev/null; then
    log "expb installed: $(expb --version 2>/dev/null || echo 'version unknown')"
else
    log "WARNING: expb installed but not on PATH. Check uv tool bin directory."
fi

# Create local config template if it doesn't exist
CONFIG_FILE="$SCRIPT_DIR/expb-local.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    log "Creating local EXPB config template: $CONFIG_FILE"
    cat > "$CONFIG_FILE" << 'YAML_EOF'
# EXPB local benchmark config
# Used by run-expb-local.sh for real-payload validation
#
# This template is rendered by run-expb-local.sh which replaces:
#   <<DOCKER_TAG>> with the actual image tag
#   <<DELAY>> with the inter-payload delay

scenarios:
  nethermind:
    client: nethermind
    docker_image: "nethermind-perf:<<DOCKER_TAG>>"
    extra_flags: []
    delay: <<DELAY>>

# Payload set — uses a small local set for quick validation
# Override with EXPB_PAYLOAD_SET env var
payload_set: "halfpath"
mode: "halfpath"
YAML_EOF
fi

log "Setup complete."
log "  Config template: $CONFIG_FILE"
log "  Run benchmarks:  ./tools/perf-agents/run-expb-local.sh <BRANCH>"
