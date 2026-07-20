#!/usr/bin/env bash
# Read-only gitlore-memory detector for the handoff skill. Invoked by the
# agent through bin/handoff-memory-probe (on PATH) during the handoff
# snapshot. Owns the entire dirty-or-not branch so the skill body carries no
# conditional: prints the agent's next action on stdout, or stays silent when
# there is nothing to commit.
#
# The directive text lives in _probe-lib.sh, shared with precompact-probe.sh.
# handoff composes the memory directive alone — the SDD ledger nudge is a
# precompact concern (compaction paraphrases; a /clear handoff does not).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_probe-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_probe-lib.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

probe_memory_directive "$root"
