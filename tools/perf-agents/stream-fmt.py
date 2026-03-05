#!/usr/bin/env python3
"""
stream-fmt.py — Format Claude stream-json into readable terminal output.

Reads NDJSON from stdin (claude --output-format stream-json), prints:
  - Assistant text as-is (streaming)
  - Tool use: name + key input fields
  - Tool results: truncated summary
  - Turn boundaries with token counts

Raw NDJSON is preserved in the log file by tee in worker.sh.
This script only formats what goes to the terminal.

Usage:
    claude -p ... --output-format stream-json | tee log.jsonl | python3 stream-fmt.py
"""

import json
import sys

# ANSI colors
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
BOLD = "\033[1m"
RESET = "\033[0m"

# State tracking
current_block_type = None
current_tool_name = None
tool_input_json = ""
in_text_block = False


def truncate(s: str, max_len: int = 200) -> str:
    s = s.strip()
    if len(s) <= max_len:
        return s
    return s[:max_len] + "..."


def format_tool_input(name: str, raw_json: str) -> str:
    """Extract key fields from tool input for display."""
    try:
        inp = json.loads(raw_json)
    except (json.JSONDecodeError, ValueError):
        return truncate(raw_json)

    if name == "Read":
        return inp.get("file_path", raw_json)
    if name == "Write":
        path = inp.get("file_path", "?")
        content = inp.get("content", "")
        lines = content.count("\n") + 1
        return f"{path} ({lines} lines)"
    if name == "Edit":
        path = inp.get("file_path", "?")
        old = truncate(inp.get("old_string", ""), 60)
        return f'{path} "{old}" -> ...'
    if name == "Bash":
        return inp.get("command", raw_json)
    if name == "Glob":
        return inp.get("pattern", raw_json)
    if name == "Grep":
        pattern = inp.get("pattern", "?")
        path = inp.get("path", ".")
        return f'/{pattern}/ in {path}'
    if name == "Agent":
        desc = inp.get("description", "")
        agent_type = inp.get("subagent_type", "")
        return f"{agent_type}: {desc}" if agent_type else desc

    return truncate(raw_json, 120)


def handle_event(event: dict):
    global current_block_type, current_tool_name, tool_input_json, in_text_block

    etype = event.get("type", "")

    if etype == "message_start":
        pass

    elif etype == "content_block_start":
        block = event.get("content_block", {})
        current_block_type = block.get("type")

        if current_block_type == "text":
            in_text_block = True
        elif current_block_type == "tool_use":
            current_tool_name = block.get("name", "?")
            tool_input_json = ""
            if in_text_block:
                print()  # newline after text before tool
                in_text_block = False

    elif etype == "content_block_delta":
        delta = event.get("delta", {})
        dtype = delta.get("type")

        if dtype == "text_delta":
            text = delta.get("text", "")
            print(text, end="", flush=True)

        elif dtype == "input_json_delta":
            tool_input_json += delta.get("partial_json", "")

    elif etype == "content_block_stop":
        if current_block_type == "tool_use" and current_tool_name:
            summary = format_tool_input(current_tool_name, tool_input_json)
            print(f"\n{CYAN}>>> {current_tool_name}{RESET} {DIM}{summary}{RESET}", flush=True)
            current_tool_name = None
            tool_input_json = ""

        if current_block_type == "text":
            in_text_block = False

        current_block_type = None

    elif etype == "message_delta":
        usage = event.get("usage", {})
        output_tokens = usage.get("output_tokens", 0)
        stop_reason = event.get("delta", {}).get("stop_reason", "")
        if output_tokens:
            print(f"\n{DIM}--- {stop_reason} ({output_tokens} tokens) ---{RESET}", flush=True)

    elif etype == "message_stop":
        pass

    # Handle tool results (these come as separate messages in the stream)
    elif etype == "result":
        result_text = event.get("result", "")
        if result_text:
            print(f"{GREEN}{truncate(str(result_text), 300)}{RESET}", flush=True)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        if obj.get("type") == "stream_event":
            event = obj.get("event", {})
            handle_event(event)
        elif "event" in obj:
            handle_event(obj["event"])
        else:
            handle_event(obj)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        pass
