#!/usr/bin/env bash
# Shared helpers for scripts/checkpoint.sh (handoff-checkpoint) and, for
# checkpoint_is_empty_body, scripts/write-stage.sh. Renamed from
# _probe-lib.sh: the directive functions below are unchanged in content and
# composition order (FR9) from the two read-only probes they replaced; only
# the probe_* -> checkpoint_* names and the mode source moved. See DESIGN.md,
# "One channel, one writer".
#
# Sourced, never executed. Each directive function takes the git worktree
# root and either prints its directive or stays silent; both always return
# 0, so callers need no conditional.

# True (rc 0) when $1's content has no substance once heading and blank lines
# are stripped: a `## Remaining` with no items, a task file with headings and
# no content. This is the generic form of FR6 ("file present => content
# pending"), and the one helper that decides it — shared by checkpoint.sh
# (after a Write/Edit it just applied) and write-stage.sh (after the agent's
# own direct Write/Edit to handoff-todo.md) so the two writers cannot drift on
# what counts as empty.
checkpoint_is_empty_body() {
    local content="$1" line
    while IFS= read -r line; do
        case "$line" in
            '#'* | '') ;;
            *) return 1 ;;
        esac
    done <<<"$content"
    return 0
}

# Emit the gitlore memory-commit directive when the gitlore-memory submodule is
# registered (FR12 activation gate) and its worktree is dirty. Silent otherwise.
#
# $2 is the commit-awareness mode, and it selects which of gitlore's two commit
# paths the agent is told to take. The IPC is the same either way — write files,
# never Bash, so it sidesteps the sandbox and the auto-mode classifier that made
# a `commit-memory.sh -F -` call fragile — and the whole difference is one file:
#
#   without-commit  summary + trigger -> gitlore's PostToolBatch commits memory
#                                        on the spot, standalone
#   with-commit     summary only      -> the parent commit's pre-commit hook
#                                        commits memory into that same commit
#
# Both end with one parent commit carrying the source change and the gitlink
# bump, so the second is not a history fix — it is one call instead of two, and
# agents batch the two writes into a single message only 43% of the time (see
# DESIGN.md, "Commit awareness"). Couples only to the two IPC filenames — never
# gitlore internals.
#
# The with-commit text never mentions the trigger — not its path, not the idea
# of one. Its reader is a fresh agent with no other source for that filename, so
# saying nothing is what makes the standalone commit unreachable; a prohibition
# would instead introduce the thing it forbids. It states no mechanism either —
# not the pre-commit hook, not the mtime freshness rule — because mechanism in a
# directive gets verified, narrated, and worked around. Nor does it order the
# write against the memory edits: "once approved" already places it after them,
# and approval is the end of a feedback loop — the user may well ask for a
# memory change there, which is what review is for. What survives is the one act
# the agent performs.
checkpoint_memory_directive() {
    local root="$1" mode="$2" mempath mem status msgfile trigger approve_files
    local clause_file clause

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

    # gitlore is the single source of truth for the approval-body wording (see
    # gitlore's docs/design.md D19); this discovers it the same way handoff
    # already discovers gitlore.commitCommand — a key gitlore seeds at install
    # and re-pins every SessionStart. No fallback copy here: the wording is
    # only ever needed while gitlore is genuinely active, so a stale local copy
    # could never be more correct than reporting the gap.
    clause_file=$(git -C "$root" config --get gitlore.memoryApprovalClauseFile 2>/dev/null) || clause_file=""
    if [ -z "$clause_file" ] || [ ! -r "$clause_file" ]; then
        printf '%s\n' \
"gitlore memory has uncommitted changes, but this session cannot read the memory-approval wording (git config gitlore.memoryApprovalClauseFile is unset or its file is missing) — the gitlore plugin looks disabled or not installed for this session. Check /plugin to enable gitlore, then retry; nothing has been written and the memory changes are still pending."
        return 0
    fi
    clause=$(cat "$clause_file")

    # The IPC files live in the superproject's .claude/ — which is $root by
    # construction, since mempath was read out of $root/.gitmodules and is
    # relative to it. (`git -C "$mem" rev-parse --show-superproject-working-tree`
    # resolves the same path via an extra subprocess, and returns empty for a
    # nested repo that is not a registered submodule.) gitlore gitignores both.
    msgfile="$root/.claude/gitlore-memory-message"
    trigger="$root/.claude/gitlore-commit-memory"

    # with-commit writes one file, without-commit two — the approval gate has to
    # say which, since it is the gate on writing them.
    if [ "$mode" = "with-commit" ]; then
        approve_files="the file below"
    else
        approve_files="either file below"
    fi

    # The summary file is the memory commit's message: gitlore feeds it to
    # `git commit -F` verbatim, in the submodule and in each tier. So the shape
    # asked for is a commit message's — title line, blank line, body.
    printf '%s\n' \
"gitlore memory has uncommitted changes:" \
"" \
"$status" \
"" \
"Summarize these changes as a commit message: a title line of at most 72 characters, a blank line, then a body with $clause. Present it to the user as a markdown blockquote (lines prefixed with '> ', not a code fence) and get their approval — they may edit it. Do not write $approve_files before the user approves." \
""

    if [ "$mode" = "with-commit" ]; then
        printf '%s\n' \
"Once approved, write the approved summary to:" \
"" \
"     $msgfile" \
"" \
"The commit that lands these changes carries the memory. Nothing further is needed from you."
    else
        printf '%s\n' \
"Once approved, commit the memory with two file writes (no Bash):" \
"" \
"  1. Write the approved summary to:" \
"     $msgfile" \
"  2. Write the trigger file (any content) to:" \
"     $trigger"
    fi
}

# Registry of known workflow-owned progress ledgers, as project-relative paths.
# Prints the live one and returns 0; returns 1 when there is none. One row per
# workflow — the single place that knows a foreign ledger's layout, so the nudge
# and the suppression below can never disagree about what exists. Callers
# interpolate what this prints; nothing downstream hardcodes a ledger path.
#
# What has to be detected is **liveness**, not presence. superpowers SDD (6.2.0)
# gives each plan its own git-ignored workspace at
# `.superpowers/sdd/<plan-basename>/progress.md`, and deletes that directory when
# the plan's final whole-branch review comes back clean. So two things do not
# count as a ledger:
#
#   - The pre-6.2.0 flat path `.superpowers/sdd/progress.md`. Nothing in SDD's
#     lifecycle removes it — it sits in no workspace — and the skill names it
#     explicitly as another plan's progress, to be left in place. Treating it as
#     authoritative suppressed handoff-todo.md in a session that ran no SDD at
#     all, which is the whole defect this shape exists to avoid, inverted.
#   - A file at a workspace path whose first line is not SDD's identity line,
#     `# SDD ledger — plan: <plan file>`. That line is what separates a live
#     ledger from a hand-rolled file that happens to sit in the right place, and
#     it costs one read. A near-miss fails open: no ledger found means
#     handoff-todo.md gets written, which is the safe direction.
#
# Several workspaces can coexist — an abandoned run leaves one behind — so the
# most recently modified wins. That is the honest signal for the one in play;
# glob order is not. Equal mtimes fall back to glob order, which is lexical.
#
# Read-only by contract: a stale workspace is another workflow's file, never
# ours to delete or rewrite however abandoned it looks.
checkpoint_ledger_path() {
    local root="$1" f best='' first

    for f in "$root"/.superpowers/sdd/*/progress.md; do
        # Also rejects the unmatched glob, which bash leaves literal.
        [ -f "$f" ] || continue
        first=''
        # A ledger whose only line lacks a trailing newline still counts: `read`
        # reports failure but has set $first.
        IFS= read -r first < "$f" || [ -n "$first" ] || continue
        case "$first" in
            '# SDD ledger — plan: '*) ;;
            *) continue ;;
        esac
        [ -z "$best" ] || [ "$f" -nt "$best" ] || continue
        best="$f"
    done

    [ -n "$best" ] || return 1
    printf '%s\n' "${best#"$root"/}"
}

# Emit the durable-progress nudge when a known structured-workflow ledger
# exists. Silent otherwise.
#
# The compaction summary paraphrases; a durable ledger does not, and workflows
# like superpowers SDD trust their ledger over post-compaction recollection.
# Advisory — a nudge, not a gate.
checkpoint_sdd_directive() {
    local root="$1" ledger

    ledger=$(checkpoint_ledger_path "$root") || return 0

    printf '%s\n' \
"You are running superpowers SDD. Before compacting, bring the ledger current at $ledger — after compaction the SDD skill trusts the ledger over recollection. Ensure:" \
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
# is the only ledger and the checkpoint writes it normally.
#
# The handoff path's counterpart to the stand-down that checkpoint_sdd_directive
# folds into its nudge: the ledger outlives a /clear exactly as it outlives a
# compaction. The wording differs on one point, because the orderings differ.
# precompact's checkpoint call runs BEFORE the writes it drives, so "do not
# write it" lands in time. handoff's checkpoint call carries the writes in the
# SAME payload, so this always arrives after the file may already exist — a
# bare prohibition is a no-op there, and the directive has to name the cleanup
# instead.
checkpoint_todo_suppression() {
    local root="$1" ledger

    ledger=$(checkpoint_ledger_path "$root") || return 0

    printf '%s\n' \
"This session's task list lives in a workflow-owned progress ledger at $ledger, which survives the /clear. That file is the ledger: .claude/handoff-todo.md must not exist alongside it — delete it if you have already written it, and do not write it. Bring the ledger current instead if it has drifted."
}
