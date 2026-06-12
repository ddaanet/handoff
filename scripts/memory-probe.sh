#!/usr/bin/env bash
# Read-only gitlore-memory detector for the handoff skill. Invoked by the
# agent through bin/handoff-memory-probe (on PATH) during the handoff
# snapshot. Owns the entire dirty-or-not branch so the skill body carries no
# conditional: prints the agent's next action on stdout, or stays silent when
# there is nothing to commit.
#
# Couples only to two public gitlore contracts: the gitlore-memory submodule
# registration in .gitmodules (FR12 activation gate) and the
# `git config gitlore.commitCommand` discovery key. No reach into gitlore
# internals; the commit machinery stays in gitlore's commit-memory.sh.
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# FR12 activation gate: the gitlore-memory submodule registration.
mempath=$(git config --file "$root/.gitmodules" \
    submodule.gitlore-memory.path 2>/dev/null) || exit 0
[ -n "$mempath" ] || exit 0

mem="$root/$mempath"
# Submodule worktree not materialized (session-less checkout): nothing to do.
[ -e "$mem/.git" ] || exit 0

# Clean memory: nothing to commit.
status=$(git -C "$mem" status --porcelain 2>/dev/null)
[ -n "$status" ] || exit 0

# Dirty. Resolve gitlore's blessed committer (absolute path, self-healing key).
script=$(git config gitlore.commitCommand 2>/dev/null || true)
if [ -z "$script" ] || [ ! -x "$script" ]; then
    printf '%s\n' \
"gitlore memory has uncommitted changes, but its commit command is not resolvable (gitlore.commitCommand = '${script:-unset}'). Tell the user to restart the session so gitlore re-pins it, then memory can be committed."
    exit 0
fi

printf '%s\n' \
"gitlore memory has uncommitted changes:" \
"" \
"$status" \
"" \
"Summarize these changes in 1-3 sentences. Present the summary to the user for approval (they may edit it). Once approved, commit the memory by piping the approved summary on stdin:" \
"" \
"    $script -F -"
