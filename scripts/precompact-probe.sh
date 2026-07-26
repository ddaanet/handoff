#!/usr/bin/env bash
# Read-only pre-compaction detector for the precompact skill. Invoked by the
# agent through bin/handoff-precompact-probe (on PATH) before a manual
# /compact. Owns the plugin-specific vocabulary so the skill body stays
# vocab-free: composes two directives on stdout, or stays silent when neither
# applies.
#
#   dirty gitlore memory -> file-trigger memory-commit directive
#   SDD progress ledger  -> bring-the-ledger-current nudge
#
# Memory goes first: it is the flow's one interactive gate (FR11 approval), and
# the commit must land while context is still full, before the summariser runs.
# Both directive bodies live in _probe-lib.sh, shared with memory-probe.sh.
#
# Usage: handoff-precompact-probe <with-commit|without-commit>
#
# The one argument is the single fact the agent supplies — whether a commit is
# going to carry this session's memory — and it selects the memory commit path.
# The agent answers the question; the branch is here.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_probe-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_probe-lib.sh"

probe_require_mode handoff-precompact-probe "$@"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

memory=$(probe_memory_directive "$root" "$PROBE_MODE")
sdd=$(probe_sdd_directive "$root")

# Blank line between them only when both fired.
if [ -n "$memory" ] && [ -n "$sdd" ]; then
    printf '%s\n\n%s\n' "$memory" "$sdd"
elif [ -n "$memory" ]; then
    printf '%s\n' "$memory"
elif [ -n "$sdd" ]; then
    printf '%s\n' "$sdd"
fi
