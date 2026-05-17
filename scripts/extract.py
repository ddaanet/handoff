#!/usr/bin/env python3
"""Extract session data into `.claude/handoff.md`.

Output format:

    # Handoff — <timestamp>

    Session: `<session-id>`

    @handoff-task.md

    ## Files touched
    - ...

    ## Last user prompts

    **after <anchor>**
    > <verbatim prompt>
    ...

The `@handoff-task.md` line is resolved by Claude Code's `@`
reference expansion when the outer `handoff.md` is included. Claude
Code resolves `@` paths relative to the file containing the
reference, so this points to `./.claude/handoff-task.md` (same
directory as `handoff.md`). The task file is agent-authored from
the SKILL.md template.

Usage:
    extract.py <transcript.jsonl> <output.md>

Missing or empty transcript is treated as "no session data" — the file
is still written with the @ ref and an empty-section note.
"""
from __future__ import annotations

import datetime as _dt
import json
import pathlib
import sys

LAST_N_PROMPTS = 5
MAX_FILES = 30
ANCHOR_TEXT_LIMIT = 120

WRAPPER_PREFIXES = (
    "<local-command-",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<system-reminder>",
    "Base directory for this skill:",
)

WRAPPER_EXACT = frozenset({
    "[Request interrupted by user]",
})


def load_entries(transcript: pathlib.Path) -> list[dict]:
    # Strip sidechain entries at load — defence-in-depth against
    # sub-agent rollups being interleaved into the main JSONL.
    entries: list[dict] = []
    for line in transcript.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("isSidechain"):
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
                    return text.splitlines()[0][:ANCHOR_TEXT_LIMIT]
        return "(silent agent turn)"
    return "(session start)"


def format_quote(text: str) -> list[str]:
    return [f"> {line}" if line.strip() else ">" for line in text.splitlines()]


def emit(transcript_path: str, output_path: pathlib.Path) -> None:
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
    lines.append("@handoff-task.md")
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
            lines.append(f"**after {anchor}**")
            lines.append("")
            lines.extend(format_quote(text))
            lines.append("")
    else:
        lines.append("(none extracted)")
        lines.append("")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <transcript.jsonl> <output.md>", file=sys.stderr)
        return 2
    emit(argv[1], pathlib.Path(argv[2]))
    print(argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
