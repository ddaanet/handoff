#!/usr/bin/env bash
# SessionStart, every source (startup, resume, clear, compact): re-arm the
# context-size nudge and sweep this plugin's own stale files at
# $HANDOFF_POINTER_DIR.
#
# Used to also publish this session's resolved root here, at a session-keyed
# path handoff-checkpoint (running in the agent's own Bash, where
# CLAUDE_PROJECT_DIR is unset) could address blind. Replaced by
# scripts/inject-checkpoint-root.sh (PreToolUse(Bash)), which resolves the
# root fresh on every matching call and injects it straight into the command
# instead — a sample taken here could be stamped from the wrong repo:
# SessionStart(resume) fires with the RESUMING process's cwd, before the
# harness moves the session into its own project dir. See
# plans/2026-08-05-checkpoint-root-via-updatedinput.md.
#
# Its own script rather than a preamble on the two loaders, because the sweep
# must be unconditional and both of those are gated (load-handoff.sh on the
# task file, load-compact.sh on a pending transition). The wildcard matcher
# also reaches `resume`, which neither loader is wired for.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

session_id="$(jq -r '.session_id // ""')"

# The session id is the whole address for the context marker below. Without
# it there is nothing to key it on.
[[ -n "$session_id" ]] || exit 0

mkdir -p "$HANDOFF_POINTER_DIR"

# Re-arm the context-size nudge. It fires once per climb, gated by a marker it
# writes itself; a SessionStart is the harness-authoritative signal that the
# context was rebuilt — compact (auto-compaction included), clear, or a resume
# that restored it whole. Inferring the re-arm from a later measurement falling
# back under the threshold is the form this design rules out.
rm -f "$(handoff_context_path "$session_id")"

# Sweep what earlier sessions left behind. None of these files has an owner
# that outlives the session: the drift marker is written by the report hook
# and cleared only if the cwd comes back, the context marker is cleared above
# and only for this session — and a session ends without either being told.
# SessionEnd would not close it, since a crash or a kill fires nothing.
# `handoff-root-*` stays on the filter to clean up whatever the old pointer
# left on disk; nothing publishes new ones.
#
# So the producer sweeps, on the way in. This runs once per session start,
# which is the only moment anything of this plugin's runs in that directory.
#
# Scoped to the names this plugin ever published, at the one level they were
# published at: the directory is a shared literal path holding files this
# plugin never wrote. A week is far past any session that would still read a
# live one.
find "$HANDOFF_POINTER_DIR" -maxdepth 1 \
    \( -name 'handoff-root-*' -o -name 'handoff-drift-*' \
       -o -name 'handoff-context-*' \) \
    -mtime +7 -delete
