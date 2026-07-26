#!/usr/bin/env bash
# Read-only gitlore-memory detector for the handoff skill. Invoked by the
# agent through bin/handoff-memory-probe (on PATH) during the handoff
# snapshot. Owns the entire dirty-or-not branch so the skill body carries no
# conditional: prints the agent's next action on stdout, or stays silent when
# there is nothing to commit.
#
# The directive text lives in _probe-lib.sh, shared with precompact-probe.sh.
# handoff composes the memory directive plus the todo-file suppression. It does
# NOT carry the SDD bring-the-ledger-current nudge — that is a precompact
# concern (compaction paraphrases; a /clear handoff does not). The suppression
# is a different question and does apply here: a workflow ledger outlives a
# /clear just as it outlives a compaction, so handoff-todo.md must stand down
# for it either way.
#
# Usage: handoff-memory-probe <with-commit|without-commit>
#
# The one argument is the single fact the agent supplies — whether a commit is
# going to carry this session's memory — and it selects the memory commit path.
# The agent answers the question; the branch is here.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_probe-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_probe-lib.sh"

probe_require_mode handoff-memory-probe "$@"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

memory=$(probe_memory_directive "$root" "$PROBE_MODE")
todo=$(probe_todo_suppression "$root")

# Blank line between them only when both fired.
if [ -n "$memory" ] && [ -n "$todo" ]; then
    printf '%s\n\n%s\n' "$memory" "$todo"
elif [ -n "$memory" ]; then
    printf '%s\n' "$memory"
elif [ -n "$todo" ]; then
    printf '%s\n' "$todo"
fi
