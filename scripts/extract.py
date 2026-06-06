#!/usr/bin/env python3
"""Extract session data and emit to stdout.

Output format:

    # Handoff — <timestamp>

    Session: `<session-id>`

    <inlined contents of ./.claude/handoff-task.md, if it exists>

    ## Files touched
    - ...

    ## Last user prompts

    **after <anchor>**
    > <verbatim prompt>
    ...

The task content is read from the `handoff-task.md` argument and inlined
verbatim (rstripped, plus one trailing blank line). The task file is
agent-authored from the SKILL.md template; if missing, the inlined block
is omitted entirely (no placeholder text, no orphan heading).

Usage:
    extract.py <transcript.jsonl> <handoff-task.md>

Missing or empty transcript is treated as "no session data" — output is
still emitted with the extracted sections (or empty-section notes) plus
whatever the task file contains.
"""
from __future__ import annotations

import datetime as _dt
import json
import pathlib
import sys

LAST_N_PROMPTS = 5
MAX_FILES = 30
ANCHOR_TEXT_LIMIT = 120
ANCHOR_LINE_LIMIT = 7    # show all lines if count <= this; truncation hides ≥2 lines
ANCHOR_HEAD_LINES = 3    # lines shown before [...]
ANCHOR_TAIL_LINES = 3    # lines shown after [...]

WRAPPER_PREFIXES = (
    "<local-command-",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<system-reminder>",
    "<task-notification>",
    "Base directory for this skill:",
)

WRAPPER_EXACT = frozenset({
    "[Request interrupted by user]",
})

def _is_handoff_write(entry: dict) -> bool:
    """True when this assistant entry writes or edits handoff-task.md."""
    msg = entry.get("message") or {}
    if msg.get("role") != "assistant":
        return False
    for block in msg.get("content") or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") != "tool_use":
            continue
        if block.get("name") not in ("Write", "Edit"):
            continue
        file_path = (block.get("input") or {}).get("file_path") or ""
        if file_path.endswith("handoff-task.md"):
            return True
    return False


def clamp_anchor_lines(lines: list[str]) -> list[str]:
    if len(lines) <= ANCHOR_LINE_LIMIT:
        return lines
    n = len(lines) - ANCHOR_HEAD_LINES - ANCHOR_TAIL_LINES
    return lines[:ANCHOR_HEAD_LINES] + [f"[ {n} lines omitted ]"] + lines[-ANCHOR_TAIL_LINES:]


def load_entries(transcript: pathlib.Path) -> list[dict]:
    raw: list[dict] = []
    for line in transcript.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            raw.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    # Bound at the last write to handoff-task.md. Agents sometimes update the
    # task after later user input, so cutting at the write (not at skill
    # activation) captures those correction prompts in the last-N window.
    cut = len(raw)
    for i in range(len(raw) - 1, -1, -1):
        if _is_handoff_write(raw[i]):
            cut = i
            break
    entries: list[dict] = []
    for entry in raw[:cut]:
        if entry.get("isSidechain") or entry.get("isMeta"):
            continue
        entries.append(entry)
    return entries


def extract_files_touched(entries: list[dict]) -> list[str]:
    seen: list[str] = []
    for entry in entries:
        message = entry.get("message") or {}
        if message.get("role") != "assistant":
            continue
        for block in message.get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            if block.get("name") not in ("Edit", "Write"):
                continue
            path = (block.get("input") or {}).get("file_path")
            if path and path not in seen:
                seen.append(path)
    return seen[-MAX_FILES:]


def user_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    non_result = [b for b in content if isinstance(b, dict) and b.get("type") != "tool_result"]
    if not non_result:
        return ""
    parts: list[str] = []
    for b in non_result:
        btype = b.get("type")
        if btype == "text":
            parts.append(b.get("text", ""))
        else:
            parts.append(f"[{btype} block]")
    return "\n".join(p for p in parts if p).strip()


def is_wrapper_entry(text: str) -> bool:
    stripped = text.strip()
    if stripped in WRAPPER_EXACT:
        return True
    return stripped.startswith(WRAPPER_PREFIXES)


def extract_user_prompts(entries: list[dict]) -> list[tuple[int, str]]:
    result: list[tuple[int, str]] = []
    for i, entry in enumerate(entries):
        if entry.get("type") != "user":
            continue
        message = entry.get("message") or {}
        text = user_text(message)
        if not text or is_wrapper_entry(text):
            continue
        result.append((i, text))
    return result


def anchor_for(entries: list[dict], user_index: int) -> str:
    for j in range(user_index - 1, -1, -1):
        entry = entries[j]
        message = entry.get("message") or {}
        if message.get("role") != "assistant":
            continue
        for block in message.get("content") or []:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "tool_use":
                name = block.get("name", "tool")
                inp = block.get("input") or {}
                target = (
                    inp.get("file_path")
                    or inp.get("pattern")
                    or (inp.get("command") or "")[:ANCHOR_TEXT_LIMIT]
                )
                return f"[{name}] {target}".strip() if target else f"[{name}]"
            if btype == "text":
                text = (block.get("text") or "").strip()
                if text:
                    return "\n".join(clamp_anchor_lines(text.splitlines()))
        return "(silent agent turn)"
    return "(session start)"


def format_quote(text: str) -> list[str]:
    return [f"> {line}" if line.strip() else ">" for line in text.splitlines()]


def emit(transcript_path: str, task_path: str) -> None:
    entries: list[dict] = []
    transcript = pathlib.Path(transcript_path) if transcript_path else None
    if transcript and transcript.exists():
        entries = load_entries(transcript)

    files_touched = extract_files_touched(entries)
    user_prompts = extract_user_prompts(entries)
    tail_prompts = user_prompts[-LAST_N_PROMPTS:]

    now = _dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    session_id = transcript.stem if transcript else "(no transcript)"

    lines: list[str] = []
    lines.append(f"# Handoff — {now}")
    lines.append("")
    lines.append(f"Session: `{session_id}`")
    lines.append("")
    task = pathlib.Path(task_path)
    if task.exists():
        task_content = task.read_text(encoding="utf-8", errors="replace").rstrip()
        if task_content:
            lines.append(task_content)
            lines.append("")
    lines.append("## Files touched")
    if files_touched:
        for path in files_touched:
            lines.append(f"- `{path}`")
    else:
        lines.append("(none extracted)")
    lines.append("")
    lines.append("## Last user prompts")
    lines.append("")
    if tail_prompts:
        for idx, text in tail_prompts:
            anchor = anchor_for(entries, idx)
            anchor_lines = anchor.splitlines()
            lines.append(f"**after** {anchor_lines[0]}")
            for al in anchor_lines[1:]:
                lines.append(al)
            lines.append("")
            lines.extend(format_quote(text))
            lines.append("")
    else:
        lines.append("(none extracted)")
        lines.append("")
    sys.stdout.write("\n".join(lines))


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <transcript.jsonl> <handoff-task.md>", file=sys.stderr)
        return 2
    emit(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
