#!/usr/bin/env bash
# Read-only durable-progress detector for the precompact skill. Invoked by the
# agent through bin/handoff-precompact-probe (on PATH) before a manual
# /compact. Owns the plugin-specific vocabulary so the skill body stays
# vocab-free: prints a flush directive on stdout when a known structured-
# workflow progress ledger exists, or stays silent when none does.
#
# The compaction summary paraphrases; a durable ledger does not, and workflows
# like superpowers SDD trust their ledger over post-compaction recollection.
# This probe nudges the operator to bring that ledger current before the
# summariser runs. It is advisory — a nudge, not a commit gate.
#
# Registry of known ledgers is the case block below; add a row per workflow.
# Detection is file existence under the git worktree root — the same root the
# workflows resolve via `git rev-parse --show-toplevel`. No git root means no
# known ledger can exist, so the probe is silent.
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# superpowers SDD: .superpowers/sdd/progress.md (git-ignored scratch, so it
# never shows in `git status` — existence is the only signal).
if [ -f "$root/.superpowers/sdd/progress.md" ]; then
    printf '%s\n' \
"You are running superpowers SDD. Before compacting, bring the ledger current at .superpowers/sdd/progress.md — after compaction the SDD skill trusts the ledger over recollection. Ensure:" \
"" \
"  - every task whose review came back clean has its \`Task N: complete (commits <base>..<head>, review clean)\` line" \
"  - any Minor findings seen so far are recorded for the final whole-branch review" \
"" \
"A task that completed but is missing from the ledger can be re-dispatched after compaction — the most expensive SDD failure."
    exit 0
fi

exit 0
