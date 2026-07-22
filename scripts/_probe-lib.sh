#!/usr/bin/env bash
# Shared directive text for the two read-only probes:
#   memory-probe.sh     (handoff-memory-probe)     -> memory directive alone
#   precompact-probe.sh (handoff-precompact-probe) -> memory directive + SDD
#
# One authored prompt, two composition points. Both directives are written to
# stdout for the agent to act on, so the wording is imperative — this is a
# DIRECTIVE channel, not a DENY channel.
#
# Sourced, never executed. Each function takes the git worktree root and either
# prints its directive or stays silent; both always return 0, so callers need
# no conditional.

# Emit the gitlore memory-commit directive when the gitlore-memory submodule is
# registered (FR12 activation gate) and its worktree is dirty. Silent otherwise.
#
# The commit runs through gitlore's file-trigger IPC, not a Bash call: the agent
# writes an approved message file plus a trigger file, and gitlore's
# PostToolBatch hook does the commit. All file writes, so it sidesteps the
# sandbox and the auto-mode classifier that make a `commit-memory.sh -F -` Bash
# call fragile. Couples only to the two IPC filenames — never gitlore internals.
probe_memory_directive() {
    local root="$1" mempath mem status msgfile trigger

    # FR12 activation gate: the gitlore-memory submodule registration.
    mempath=$(git config --file "$root/.gitmodules" \
        submodule.gitlore-memory.path 2>/dev/null) || return 0
    [ -n "$mempath" ] || return 0

    mem="$root/$mempath"
    # Submodule worktree not materialized (session-less checkout): nothing to do.
    [ -e "$mem/.git" ] || return 0

    # Clean memory: nothing to commit.
    status=$(git -C "$mem" status --porcelain 2>/dev/null)
    [ -n "$status" ] || return 0

    # The IPC files live in the superproject's .claude/ — which is $root by
    # construction, since mempath was read out of $root/.gitmodules and is
    # relative to it. (`git -C "$mem" rev-parse --show-superproject-working-tree`
    # resolves the same path via an extra subprocess, and returns empty for a
    # nested repo that is not a registered submodule.) gitlore gitignores both.
    msgfile="$root/.claude/gitlore-memory-message"
    trigger="$root/.claude/gitlore-commit-memory"

    printf '%s\n' \
"gitlore memory has uncommitted changes:" \
"" \
"$status" \
"" \
"Summarize these changes in 1-3 sentences. Present the summary to the user as a markdown blockquote (lines prefixed with '> ', not a code fence) and get their approval — they may edit it. Do not write either file below before the user approves." \
"" \
"Once approved, commit the memory with two file writes (no Bash):" \
"" \
"  1. Write the approved summary to:" \
"     $msgfile" \
"  2. Write the trigger file (any content) to:" \
"     $trigger" \
"" \
"gitlore's PostToolBatch hook commits the submodule and removes both files on success. If they remain, the commit did not run — report that rather than retrying."
}

# Registry of known workflow-owned progress ledgers, as project-relative paths.
# Prints the first one that exists and returns 0; returns 1 when none does. One
# row per workflow — the single place that knows a foreign ledger's layout, so
# the nudge and the suppression below can never disagree about what exists.
probe_ledger_path() {
    local root="$1"

    # superpowers SDD: .superpowers/sdd/progress.md (git-ignored scratch, so it
    # never shows in `git status` — existence is the only signal).
    if [ -f "$root/.superpowers/sdd/progress.md" ]; then
        printf '.superpowers/sdd/progress.md\n'
        return 0
    fi

    return 1
}

# Emit the durable-progress nudge when a known structured-workflow ledger
# exists. Silent otherwise.
#
# The compaction summary paraphrases; a durable ledger does not, and workflows
# like superpowers SDD trust their ledger over post-compaction recollection.
# Advisory — a nudge, not a gate.
probe_sdd_directive() {
    local root="$1"

    probe_ledger_path "$root" >/dev/null || return 0

    printf '%s\n' \
"You are running superpowers SDD. Before compacting, bring the ledger current at .superpowers/sdd/progress.md — after compaction the SDD skill trusts the ledger over recollection. Ensure:" \
"" \
"  - every task whose review came back clean has its \`Task N: complete (commits <base>..<head>, review clean)\` line" \
"  - any Minor findings seen so far are recorded for the final whole-branch review" \
"" \
"A task that completed but is missing from the ledger can be re-dispatched after compaction — the most expensive SDD failure." \
"" \
"That ledger is this session's task list. Do not also write .claude/handoff-todo.md — two ledgers drift, and the stale one gets believed."
}

# Emit the todo-file suppression when a workflow-owned ledger already tracks the
# session's task list. Silent otherwise — the common case, where handoff-todo.md
# is the only ledger and the skill writes it normally.
#
# Composed by both probes: the ledger outlives a /clear exactly as it outlives a
# compaction, so the handoff path needs the same suppression the precompact path
# folds into its nudge.
probe_todo_suppression() {
    local root="$1" ledger

    ledger=$(probe_ledger_path "$root") || return 0

    printf '%s\n' \
"This session's task list lives in a workflow-owned progress ledger at $ledger, which survives the /clear. That file is the ledger: do not write .claude/handoff-todo.md. Bring the ledger current instead if it has drifted."
}
