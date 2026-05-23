#!/usr/bin/env bash
# Shared helpers for handoff hook scripts. Source-only; no shebang
# execution. Source from siblings via:
#   # shellcheck source=_lib.sh
#   source "$(dirname "$0")/_lib.sh"

# Canonical relative paths inside the project. Changing these is a
# breaking change (see CLAUDE.md conventions).
# shellcheck disable=SC2034  # consumed by sourcing scripts
HANDOFF_REL_TASK=".claude/handoff-task.md"
# shellcheck disable=SC2034
HANDOFF_REL_OUT=".claude/handoff.md"
# shellcheck disable=SC2034
HANDOFF_REL_ERR=".claude/handoff-error.log"

# Portable path canonicalization. `realpath -m` is GNU-only; BSD
# `realpath` rejects non-existent components. Python handles both and
# resolves multiple paths in one subprocess to amortize cold start.
# Prints one line per argument, in order.
handoff_resolve() {
    python3 -c 'import os,sys
for p in sys.argv[1:]: print(os.path.realpath(p))' "$@"
}

# Has the handoff:handoff skill activated in this session? Stateless:
# derive the answer from the transcript JSONL each call (no marker, no
# env). Scans for either activation signal the wipe hooks key on — a
# Skill tool_use (agent path) or the /handoff:handoff slash command
# (user path, stored as a <command-name> wrapper). Verified against real
# transcripts 2026-05-23. Exit 0 if activated, 1 otherwise (incl.
# empty/missing/unreadable transcript).
handoff_activated() {
    local transcript="$1"
    [[ -n "$transcript" && -f "$transcript" ]] || return 1
    python3 - "$transcript" <<'PY'
import json, sys

SLASH = "<command-name>/handoff:handoff</command-name>"
try:
    fh = open(sys.argv[1], encoding="utf-8", errors="replace")
except OSError:
    sys.exit(1)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("isSidechain"):
            continue
        msg = entry.get("message") or {}
        # Agent path: Skill tool_use with skill == handoff:handoff.
        if msg.get("role") == "assistant":
            for block in msg.get("content") or []:
                if (isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("name") == "Skill"
                        and (block.get("input") or {}).get("skill") == "handoff:handoff"):
                    sys.exit(0)
        # User path: slash command stored as a <command-name> wrapper.
        if entry.get("type") == "user":
            content = msg.get("content")
            if isinstance(content, str) and SLASH in content:
                sys.exit(0)
sys.exit(1)
PY
}

# Emit a PreToolUse deny on stdout, then `exit 0` (not `return`) —
# terminates the calling process, so only safe from a standalone hook
# script, not a general sourced context (subshell/interactive/setup).
# Modern permissionDecision channel, identical envelope to the wipe
# scripts. $1 = agent-facing reason (factual, no actionable phrasing);
# $2 = user-facing systemMessage.
handoff_deny() {
    jq -nc --arg r "$1" --arg s "$2" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}'
    exit 0
}
