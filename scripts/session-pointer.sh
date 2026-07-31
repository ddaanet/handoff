#!/usr/bin/env bash
# SessionStart, every source (startup, resume, clear, compact): publish this
# session's resolved handoff root where the agent's own Bash can read it back.
#
# handoff-checkpoint runs in that Bash, where CLAUDE_PROJECT_DIR is unset and
# $PWD is wherever the session cwd has drifted to — so it cannot resolve the
# root, and cannot read a file under the root either, because addressing that
# path is exactly what it cannot do. This is the bootstrap: one line, the root,
# at a session-keyed path both sides can address blind.
#
# Its own script rather than a preamble on the two loaders, because the write
# must be unconditional and both of those are gated (load-handoff.sh on the
# task file, load-compact.sh on .pending). The wildcard matcher also reaches
# `resume`, which neither loader is wired for.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

{ read -r hook_cwd; read -r session_id; } < <(
    jq -r '.cwd // "", .session_id // ""'
)

# The session id is the whole address. Without it there is nothing to key the
# pointer on, and the checkpoint refuses for want of one rather than reading
# some other session's.
[[ -n "$session_id" ]] || exit 0

root="$(handoff_root "$hook_cwd")"
[[ -n "$root" ]] || exit 0

mkdir -p "$HANDOFF_POINTER_DIR"
printf '%s\n' "$root" > "$(handoff_pointer_path "$session_id")"

# Sweep what earlier sessions left behind. Neither file has an owner that
# outlives the session: the pointer is published here and read by the agent's
# Bash, the drift marker is written by the report hook and cleared only if the
# cwd comes back — and a session ends without either being told. SessionEnd
# would not close it, since a crash or a kill fires nothing.
#
# So the producer sweeps, on the way in. This runs once per session start,
# which is the only moment anything of this plugin's runs in that directory,
# and it happens after the write above so this session's own pointer is fresh
# whatever the threshold.
#
# Scoped to the two names published here, at the one level they are published
# at: the directory is a shared literal path holding files this plugin never
# wrote. A week is far past any session that would still read its pointer, and
# every SessionStart of a live session — resume, clear, compact — refreshes it.
# A session idle past that loses its pointer and the checkpoint refuses by
# naming the restart that republishes one.
find "$HANDOFF_POINTER_DIR" -maxdepth 1 \
    \( -name 'handoff-root-*' -o -name 'handoff-drift-*' \) \
    -mtime +7 -delete
