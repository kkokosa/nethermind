#!/usr/bin/env python3
"""
MCP tool server for perf-agents.

Exposes role-specific tools that wrap existing Python/bash scripts.
Accepts --role to filter which tools are exposed.

Roles:
  researcher        — backlog_status, propose_targets
  worker-research   — backlog_status, propose_targets
  worker-implement  — ingest_benchmarks, compare_results, run_correctness_check

Usage:
  python3 mcp-server.py --role researcher
  python3 mcp-server.py --role worker-research
  python3 mcp-server.py --role worker-implement
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from mcp.server.fastmcp import FastMCP

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = Path(os.environ.get("PERF_REPO_ROOT", SCRIPT_DIR.parent.parent))
DB_PATH = Path(os.environ.get("PERF_DB_PATH", REPO_ROOT / "tools" / "perf-dashboard" / "db" / "perf.db"))

RESEARCH_ROLES = {"researcher", "worker-research"}
IMPLEMENT_ROLES = {"worker-implement"}

mcp = FastMCP("perf-tools")


def _run(cmd: list[str], cwd: str | None = None, timeout: int = 300) -> str:
    """Run a subprocess and return combined stdout+stderr."""
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=cwd or str(REPO_ROOT),
        timeout=timeout,
    )
    output = result.stdout
    if result.stderr:
        output += "\n[stderr]\n" + result.stderr
    if result.returncode != 0:
        output += f"\n[exit code: {result.returncode}]"
    return output.strip()


# ─── Research tools ──────────────────────────────────────────────────────────

@mcp.tool()
def backlog_status() -> str:
    """Query current optimization target backlog status (counts by status, top priorities)."""
    return _run([
        sys.executable, str(SCRIPT_DIR / "backlog.py"),
        "status", "--json", "--db", str(DB_PATH),
    ])


@mcp.tool()
def propose_targets(targets_json: str, source: str = "mcp-client") -> str:
    """Submit new optimization target proposals.

    Args:
        targets_json: JSON array of target proposals. Each object must have:
            area, title, description, difficulty (S/M/L), impact (high/med/low),
            confidence (0.0-1.0). Optional: parent_id, related_targets.
        source: Who is proposing (e.g. "researcher", "worker:LR-001").
    """
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        f.write(targets_json)
        tmp_path = f.name
    try:
        return _run([
            sys.executable, str(SCRIPT_DIR / "propose_target.py"),
            "--from-file", tmp_path,
            "--source", source,
            "--db", str(DB_PATH),
        ])
    finally:
        os.unlink(tmp_path)


# ─── Implement tools ─────────────────────────────────────────────────────────

@mcp.tool()
def ingest_benchmarks(loop_run_id: str, side: str, bdn_json_paths: list[str]) -> str:
    """Store BenchmarkDotNet JSON results in SQLite.

    Args:
        loop_run_id: The loop run ID (e.g. "LR-001").
        side: Either "baseline" or "candidate".
        bdn_json_paths: List of paths to BDN JSON result files.
    """
    ingest_script = REPO_ROOT / "tools" / "perf-dashboard" / "scripts" / "ingest.py"
    cmd = [
        sys.executable, str(ingest_script),
        "--loop-run", loop_run_id,
        "--side", side,
        "--db", str(DB_PATH),
        "--bdn-json",
    ] + bdn_json_paths
    return _run(cmd)


@mcp.tool()
def compare_results(loop_run_id: str) -> str:
    """Compute baseline vs candidate benchmark deltas for a loop run.

    Args:
        loop_run_id: The loop run ID (e.g. "LR-001").
    """
    compare_script = REPO_ROOT / "tools" / "perf-dashboard" / "scripts" / "compare.py"
    return _run([
        sys.executable, str(compare_script),
        "--loop-run", loop_run_id,
        "--db", str(DB_PATH),
    ])


@mcp.tool()
def run_correctness_check(target_id: str, worktree_dir: str = "") -> str:
    """Run area-specific unit tests to verify correctness after optimization.

    Args:
        target_id: The target ID (e.g. "EVM-1"). Used to select which test projects to run.
        worktree_dir: Path to the worktree directory. Defaults to current directory.
    """
    check_script = SCRIPT_DIR / "run-correctness-check.sh"
    cmd = ["bash", str(check_script), target_id]
    if worktree_dir:
        cmd.append(worktree_dir)
    return _run(cmd, timeout=600)


# ─── Role filtering ─────────────────────────────────────────────────────────

TOOL_ROLES = {
    "backlog_status": RESEARCH_ROLES,
    "propose_targets": RESEARCH_ROLES,
    "ingest_benchmarks": IMPLEMENT_ROLES,
    "compare_results": IMPLEMENT_ROLES,
    "run_correctness_check": IMPLEMENT_ROLES,
}


def filter_tools_by_role(role: str) -> None:
    """Remove tools that don't belong to the given role."""
    to_remove = []
    for tool_name, allowed_roles in TOOL_ROLES.items():
        if role not in allowed_roles:
            to_remove.append(tool_name)

    for tool_name in to_remove:
        if tool_name in mcp._tool_manager._tools:
            del mcp._tool_manager._tools[tool_name]


def main():
    parser = argparse.ArgumentParser(description="Perf-agents MCP tool server")
    parser.add_argument("--role", required=True,
                        choices=["researcher", "worker-research", "worker-implement"],
                        help="Agent role — determines which tools are exposed")
    args = parser.parse_args()

    filter_tools_by_role(args.role)
    mcp.run()


if __name__ == "__main__":
    main()
