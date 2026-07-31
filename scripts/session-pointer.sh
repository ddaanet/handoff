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
