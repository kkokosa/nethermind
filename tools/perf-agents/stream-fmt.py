#!/usr/bin/env python3
"""
stream-fmt.py — Format Claude Code stream-json into readable terminal output.

Reads NDJSON from stdin (claude --output-format stream-json), prints:
  - Assistant text as-is
  - Tool use: name + key input fields
  - Tool results: truncated summary

Claude Code stream-json format (different from raw Anthropic API):
  {"type": "system", "subtype": "init", ...}
  {"type": "assistant", "message": {"content": [...]}, ...}
  {"type": "tool_use", "tool": "Bash", "input": {...}, ...}
  {"type": "tool_result", "content": "...", ...}
  {"type": "result", "result": "...", ...}

Usage:
    claude -p ... --output-format stream-json | tee log.jsonl | python3 stream-fmt.py
"""

import json
import sys
import os
from datetime import datetime

# Force unbuffered I/O
sys.stdin = os.fdopen(sys.stdin.fileno(), 'r', buffering=1)
sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)

# ANSI colors
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
BOLD = "\033[1m"
RESET = "\033[0m"


def ts() -> str:
    """Current timestamp for log prefix."""
    return datetime.now().strftime("%H:%M:%S")


def truncate(s: str, max_len: int = 200) -> str:
    if s is None:
        return ""
    s = str(s).strip()
    if len(s) <= max_len:
        return s
    return s[:max_len] + "..."


def format_tool_input(name: str, inp: dict) -> str:
    """Extract key fields from tool input for display."""
    if not isinstance(inp, dict):
        return truncate(str(inp))

    if name == "Read":
        return inp.get("file_path", str(inp))
    if name == "Write":
        path = inp.get("file_path", "?")
        content = inp.get("content", "")
        lines = content.count("\n") + 1 if content else 0
        return f"{path} ({lines} lines)"
    if name == "Edit":
        path = inp.get("file_path", "?")
        old = truncate(inp.get("old_string", ""), 40)
        return f'{path} "{old}" -> ...'
    if name == "Bash":
        cmd = inp.get("command", str(inp))
        return truncate(cmd, 100)
    if name == "Glob":
        return inp.get("pattern", str(inp))
    if name == "Grep":
        pattern = inp.get("pattern", "?")
        path = inp.get("path", ".")
        return f'/{pattern}/ in {path}'
    if name == "Task":
        desc = inp.get("description", "")
        agent_type = inp.get("subagent_type", "")
        return f"{agent_type}: {desc}" if agent_type else desc

    return truncate(str(inp), 80)


def handle_event(event: dict):
    etype = event.get("type", "")

    if etype == "system":
        subtype = event.get("subtype", "")
        if subtype == "init":
            model = event.get("model", "?")
            print(f"{DIM}[{ts()}] [init] model={model}{RESET}", flush=True)

    elif etype == "assistant":
        message = event.get("message", {})
        content = message.get("content", [])
        for block in content:
            btype = block.get("type", "")
            if btype == "text":
                text = block.get("text", "")
                for line in text.splitlines():
                    print(f"{DIM}[{ts()}]{RESET} {line}", flush=True)
            elif btype == "thinking":
                thinking = block.get("thinking", "")
                preview = truncate(thinking, 100)
                print(f"{DIM}[{ts()}] [thinking] {preview}{RESET}", flush=True)
            elif btype == "tool_use":
                name = block.get("name", "?")
                inp = block.get("input", {})
                summary = format_tool_input(name, inp)
                print(f"{DIM}[{ts()}]{RESET} {CYAN}>>> {name}{RESET} {DIM}{summary}{RESET}", flush=True)

    elif etype == "tool_use":
        # Standalone tool_use event (alternative format)
        name = event.get("tool", event.get("name", "?"))
        inp = event.get("input", {})
        summary = format_tool_input(name, inp)
        print(f"{DIM}[{ts()}]{RESET} {CYAN}>>> {name}{RESET} {DIM}{summary}{RESET}", flush=True)

    elif etype == "tool_result":
        content = event.get("content", "")
        if isinstance(content, list):
            # Handle structured content
            texts = [c.get("text", "") for c in content if isinstance(c, dict)]
            content = "\n".join(texts)
        preview = truncate(str(content), 150)
        print(f"{DIM}[{ts()}]{RESET} {GREEN}<<< {preview}{RESET}", flush=True)

    elif etype == "user":
        # User turn (usually tool results being sent back)
        pass

    elif etype == "result":
        # Final result
        duration = event.get("duration_ms", 0)
        turns = event.get("num_turns", 0)
        cost = event.get("total_cost_usd", 0)
        stop = event.get("stop_reason", "?")
        print(f"\n{DIM}[{ts()}] --- {stop} | {turns} turns | {duration/1000:.1f}s | ${cost:.4f} ---{RESET}", flush=True)

    elif etype == "rate_limit_event":
        pass  # Ignore rate limit events


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            handle_event(obj)
        except json.JSONDecodeError:
            continue


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        pass
