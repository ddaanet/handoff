#!/usr/bin/env bash
# PreToolUse(Bash): inject this session's root into a handoff-checkpoint or
# handoff-approved invocation as HANDOFF_ROOT, since neither can resolve it
# itself — both run in the agent's Bash, where CLAUDE_PROJECT_DIR is unset and
# $PWD is wherever the session cwd has drifted to.
#
# Replaces a session-keyed pointer file (session-pointer.sh used to publish
# one at SessionStart) sampled once at the one moment the cwd does not yet
# belong to the session: SessionStart(resume) fires with the RESUMING
# process's cwd, before the harness moves the session into its own project
# dir. Resolving here, on every matching call, has no such moment — the value
# is sampled when it is used. See
# plans/2026-08-05-checkpoint-root-via-updatedinput.md.
#
# Matching is a loose command substring, deliberately asymmetric: a false
# positive costs an unused env var on an unrelated command; a false negative
# leaves HANDOFF_ROOT unset, and the two entry points refuse naming the cause.
# NFR2: this fires on every Bash call in every session with the plugin
# installed, so the negative path is one jq field parse and a substring test —
# no root resolution unless the command matches.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$DIR/_lib.sh"

payload="$(cat)"
command="$(jq -r '.tool_input.command // ""' <<<"$payload")"

case "$command" in
    *handoff-checkpoint* | *handoff-approved*) ;;
    *) exit 0 ;;
esac

cwd="$(jq -r '.cwd // ""' <<<"$payload")"
root="$(handoff_root "$cwd")"
[ -n "$root" ] || exit 0

# export …; rather than a bare VAR=… prefix, so the value survives a batched
# command: `VAR=x a && b` would apply to `a` alone, not `b`. printf %q quotes
# for bash specifically — the rewritten command always runs under bash (the
# Bash tool), so this need not be POSIX-portable.
quoted_root="$(printf '%q' "$root")"
new_command="export HANDOFF_ROOT=$quoted_root; $command"

jq -c --arg cmd "$new_command" \
    '.tool_input.command = $cmd
     | {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "injected HANDOFF_ROOT for the checkpoint channel", updatedInput: .tool_input}}' \
    <<<"$payload"
