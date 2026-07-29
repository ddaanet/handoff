# Commit awareness — design

**Date:** 2026-07-25
**Status:** implemented

## Problem

The routine wrap-up is `/handoff` then `/commit`. Today the handoff's memory
step always takes the standalone path: the agent writes gitlore's approved
summary **and** its commit trigger, and gitlore's `PostToolBatch` hook commits
the memory submodule on the spot.

That is not a history defect. The standalone commit is a *submodule* commit, and
the parent's pre-commit hook stages the moved gitlink unconditionally
(`git-hooks/pre-commit:75-91`), so the next parent commit records the source
change and the pointer bump together either way. Both paths end with one parent
commit and one memory commit. `feedback_bundle_memory_with_source` governs
parent commits and neither path violates it.

The cost is a round trip. Two file writes are free only when the agent issues
them in one tool batch, and it usually does not: over every transcript writing
either IPC file, grouped by assistant `message.id`, 28 of 65 IPC writes inside a
handoff or precompact activation batched both files and 37 split them — 43%
batched, 39% outside gitlore's own development. A split costs one extra API
round trip, median 5.9 s. So the trigger file is a wasted round trip 57% of the
time and buys nothing the bundled path does not give.

A second, smaller defect rides along. When a commit is part of the request, the
snapshot is written before it lands, so anything phrased as pending — a memory
body describing a change as proposed, a `handoff-todo.md` item saying "commit
the work" — is false the second after the user commits, and gets re-injected
that way at the next session start.

## Mechanism it turns on

gitlore's parent pre-commit hook (`lib/resolve.sh:289-358`,
`gitlore_sync_memory_to_live`) already does the bundling, and it needs one
thing from the agent: a **fresh approved summary file**. With dirty memory and
no such file it emits a directive and returns 1, which aborts the parent
commit.

The commit *trigger* (`.claude/gitlore-commit-memory`) is the only signal that
makes `PostToolBatch` commit memory standalone
(`cc-hooks/memory-commit-batch.sh:30`). So the whole difference between
"standalone" and "bundled" is one file:

| | summary file | trigger file | result |
|---|---|---|---|
| standalone | written | written | memory commits now, on its own |
| bundled | written | **not** written | memory commits inside the parent commit, gitlink staged into it |

Freshness is `msgfile mtime >= newest file in the memory worktree`
(`lib/util.sh:226-240`). A memory edit made *after* the summary file makes it
stale, and the parent commit aborts.

## Requirements

- **FR1** — When a commit is going to carry the memory, the
  handoff/precompact memory step prepares the approved summary and leaves the
  commit to the parent commit.
- **FR2** — When none is coming, behaviour is unchanged: summary + trigger,
  standalone commit.
- **FR3** — The choice is a deterministic branch in code, driven by one fact
  the agent supplies. The agent answers *"is a commit going to carry this
  session's memory?"*; it does not decide what to do about memory.
- **FR4** — The two answers are presented symmetrically. No default, no
  fallback, no safe option.
- **FR5** — Under with-commit, memory bodies are written as if the change has
  already landed. Rules that depend on the commit landing *in this request*
  carry that condition themselves rather than riding the mode.
- **FR6** — The approved summary is prescribed as a commit message: a title
  line of at most 72 characters, a blank line, then a structured body. It is
  what gitlore passes to `git commit -F`.
- **NFR1** — The handoff probe stays a single call in the same turn as the
  writes. No extra round trip.
- **NFR2** — Coupling to gitlore stays limited to the two IPC filenames.

## Architecture

### Probe CLI

`probe_memory_directive "$root" "$mode"` takes the mode as a second parameter.
Both entry points require exactly one positional argument:

```
handoff-memory-probe      with-commit | without-commit
handoff-precompact-probe  with-commit | without-commit
```

Validation is a shared helper in `_probe-lib.sh`:

```sh
probe_require_mode "<invocation name>" "$@"   # sets PROBE_MODE, or exits 2
```

It sets a global rather than printing the mode, because `exit 2` inside a
command substitution exits only the subshell and the caller would sail on with
an empty mode. Same shape as `handoff_match_target`'s `MATCHED_NAME`.

Anything other than exactly one recognized value prints
`usage: <name> <with-commit|without-commit>` on stderr and exits 2. The `bin/`
shims already forward `"$@"` and are untouched.

### Directive text

Clean memory: silent in both modes, unchanged. Dirty memory:

**Shared preamble** — the status block, then the summarize → blockquote →
approve gate. The summary is asked for as a commit message (FR6): a title line
of at most 72 characters, a blank line, then one bullet per memory file saying
what it now records. gitlore writes that file to the memory commit and to each
tier commit with `commit -F`, unedited, so the shape it prescribes is the shape
that lands in history. Mode-independent — both probes get it.

**without-commit** — today's text verbatim.

**with-commit** — same status block and the same summarize → blockquote →
approve gate, then:

- write the approved summary to `<msgfile>`;
- say that the commit which lands these changes carries the memory and nothing
  further is needed — one clause, so a reader does not read the absence of a
  commit as a failure and invent a recovery. Not "this turn's commit": a turn
  is a user turn, and handoff's routine `/handoff` then `/commit` puts the
  commit in the *next* one.

That is the whole directive. Three things an earlier draft carried were cut:

**No mention of `<trigger>` — not its path, not the concept.** The reader is a
fresh agent in an arbitrary project with no other source for that filename, so
saying nothing is what makes the standalone commit unreachable. A prohibition
would introduce the thing it forbids.

**No mechanism.** Not the pre-commit hook, not the gitlink staging, not the
mtime freshness rule. Mechanism in a directive gets verified, narrated back to
the user, and worked around by a reader who cannot act on it.

**No ordering against the memory edits.** Freshness is real — a memory edit
after the summary write aborts the parent commit — but the ordering already
falls out of the approval gate: the summary is written *once approved*, and
approval is the end of a feedback loop, not the start of one. Nothing further
is needed, in the directive or in the skill bodies.

An intermediate draft made it a skill-body rule — "memory is final at its
memory step; the flow does not return to it" — and that is worse than
redundant. Review exists to produce feedback, and acting on it routinely means
editing memory: the directive itself says the user *may edit* the summary. A
rule forbidding the return trip forbids the thing the gate is for. If a memory
edit does land after the summary write, the recovery is to write the summary
again; gitlore's abort says so at the point it happens, which is where that
knowledge is actionable.

`probe_ledger_path`, `probe_sdd_directive` and `probe_todo_suppression` are
unaffected. Composition order in both probes is unchanged.

### Skill bodies

The judgement and its content consequences live in the skill bodies; the
branch lives in the probe. This is the ordinary `harness-over-agent` split —
that rule reserves the skill body for "deciding what to write", which is what
both halves here are.

Placement is forced by *when the guidance is read*. `handoff` runs its probe in
the **same turn** as the writes, so a directive about how to write them arrives
after they exist — the defect DESIGN.md records under *A directive must fit
where in the turn it lands* (2026-07-22). The skill body is read before Step 1;
the probe output is read at the last step. So:

- **skill body** — the with-commit/without-commit decision, and the
  write-as-landed rules that Steps 2 and 3 apply;
- **probe** — the memory branch alone, read where it acts.

Both skills gain a new first step: decide the answer from the request and the
state of the work, no tool calls, two options of equal weight, no default.
Existing steps renumber. The probe invocation becomes
`handoff-memory-probe <answer>` / `handoff-precompact-probe <answer>`.

The one content rule the answer feeds: memory is written as landed under
with-commit — present-tense truth, which is the standing rule regardless.
Commit status in either handoff file is an anti-pattern in `handoff`'s list,
unconditionally and independent of the mode: the task file by template
(DESIGN.md, 2026-06-24), the todo file's "commit the work" item alongside it.

precompact gets one more rule, and it is load-bearing: **when the commit is
part of the request, it must land before `./.claude/autocompact` is written.**
Writing
`autocompact` then asking for commit approval ends the turn; `Stop` arms the
compaction, and it runs instead of the commit. Same shape as the existing
"never in the same turn as a question the directive requires".

Committing is not one of either skill's steps, but neither says so: "handoff
and commit" is the common request, and a line reading as *this skill does not
run git* would refuse it. The only thing that needs stating is the ordering
precompact depends on, which step 5 states positively.

Neither skill gains an anti-pattern for any of this. Both lists record defects
that were observed; an entry for defaulting the answer, or for running git
under `with-commit`, would be invented — and the second would forbid exactly
what the request asked for.

## Rejected alternatives

- **A third mode for "committed later, not by this request".** It would
  branch identically to `with-commit` in the probe — the routing is the same —
  so it buys a third option to weigh in exchange for renaming a shade of
  prose, against FR4's symmetry. The binary is right; the question it asked
  was wrong.
- **Detect the intent in the probe** (scrape the transcript, or key on a
  slash-command name). Not a fact a script can see, and transcript-keying is
  the maintenance trap DESIGN.md already refuses for the todo list ("The skill
  body decides, not a probe").
- **Default the argument to `without-commit`.** One line shorter, and it
  reintroduces the asymmetry: a default is the answer the agent gives when it
  does not think about the question. FR4 exists to stop that.
- **Emit the write-as-landed guidance from the probe.** Correct for
  precompact, a no-op for handoff — the same directive-position bug the todo
  suppression already had to be rewritten for.
- **Write the trigger anyway and let the parent commit bump an
  already-committed gitlink.** Produces the two-commit split the change exists
  to remove.
- **Suppress the summary file too, and let gitlore's pre-commit directive
  prompt for it.** Moves an interactive approval gate into the middle of a
  `git commit`, where the abort is the user's first sign anything is needed.

## Testing

`tests/memory-probe.bats` and `tests/precompact-probe.bats`, both building on
`tests/probe-helpers.bash`:

- both modes × dirty memory → the summary is prescribed as a commit message,
  with the 72-character title and a body
- with-commit × dirty memory → summary path present, the word "trigger"
  **absent** in any form
- without-commit × dirty memory → both paths present (existing assertions)
- both modes × clean memory → silent
- no argument → exit 2, usage on stderr
- unknown argument (`--with-commit`, `commit`, `yes`) → exit 2
- two arguments → exit 2
- precompact: composed memory-then-SDD ordering holds under both modes
- both `bin/` shims forward the argument

The load-bearing assertion is a negative — "with-commit output does not mention
the trigger". Per `feedback_mutation_check_negatives` it is verified by
removing the branch and watching that test go red, not by observing it pass.
Disabling the with-commit branch turns 7 tests red across the two suites.

As approved, this section contradicted *Directive text*, which required the
trigger to be named explicitly in a prohibition. Resolved in favour of this
section — see *Directive text* for why saying nothing is the mechanism rather
than a stylistic choice.

## Records

- `DESIGN.md` — dated section for this decision, plus a scoped
  `> **Superseded**` note on *precompact drives the compaction* (2026-07-20),
  which presents the file-trigger IPC as *the* commit path where it is now the
  without-commit path.
- `README.md` — one line in the gitlore paragraph: handoff combines correctly
  with a commit, avoiding statements that are wrong the second after it lands.
- `CLAUDE.md` — probe entries gain the argument.

## Changelog

- 2026-07-25 — initial design, approved.
- 2026-07-25 — implemented. The approved draft contradicted itself on whether
  the with-commit directive may name the trigger path: *Directive text*
  required it, *Testing* forbade it. Resolved in favour of *Testing* — the
  reader has no other source for that filename, so saying nothing is what
  makes the standalone commit unreachable, and any prohibition would supply
  what it forbids. *Directive text* also lost its mechanism paragraphs: they
  described gitlore's internals to an agent whose only acts are two file
  writes, and mechanism a reader cannot act on gets checked and narrated
  instead.
- 2026-07-25 — FR6 added: the summary is prescribed as a commit message rather
  than "1-3 sentences", since gitlore passes the file to `git commit -F`
  unedited. Shared preamble, so both modes and both probes carry it.
- 2026-07-25 — the question re-phrased from *does this request imply a commit?*
  to *is a commit going to carry this session's memory?*, after dogfooding hit
  the divergent case: no commit in the request, memory documenting the
  uncommitted implementation in the tree. The flag was carrying two conditions
  — routing and tense — that coincide in both routine cases, and their failure
  costs are not comparable. Mode values, probe branch and tests unchanged; the
  two rules that needed *this request* now say so themselves.
- 2026-07-26 — **the stated problem was wrong.** This document, `DESIGN.md`,
  `CLAUDE.md`, `README.md` and `_probe-lib.sh` all claimed the standalone path
  splits memory from the source change it documents, violating
  `feedback_bundle_memory_with_source`. It does not: the standalone commit is a
  submodule commit, the parent's pre-commit hook stages the moved gitlink
  unconditionally (`git-hooks/pre-commit:75-91`), and both paths end with one
  parent commit carrying source and pointer together. The real gain is one
  fewer file write, which matters because agents batch the two writes into a
  single assistant message only 28 times in 65 measured handoff/precompact
  activations. The asymmetric-failure-cost argument for the re-phrased question
  went with it — neither wrong answer is expensive — but the question stands,
  since routing is the half the probe branches on. No code, mode or test
  change; prose only.
