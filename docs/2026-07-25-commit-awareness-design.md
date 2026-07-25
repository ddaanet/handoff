# Commit awareness — design

**Date:** 2026-07-25
**Status:** approved, not yet implemented

## Problem

The routine wrap-up is `/handoff` then `/commit`. Today the handoff's memory
step always takes the standalone path: the agent writes gitlore's approved
summary **and** its commit trigger, and gitlore's `PostToolBatch` hook commits
the memory submodule on the spot. A parent commit then follows moments later
carrying the source change — and the memory that documents it sits in a
separate commit, already landed.

That is exactly what `feedback_bundle_memory_with_source` rules out: a memory
update belongs in the same parent commit as the source change it documents.

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

- **FR1** — When the user's request implies a commit, the handoff/precompact
  memory step prepares the approved summary and leaves the commit to the
  parent commit.
- **FR2** — When it does not, behaviour is unchanged: summary + trigger,
  standalone commit.
- **FR3** — The choice is a deterministic branch in code, driven by one fact
  the agent supplies. The agent answers *"does the request imply a commit?"*;
  it does not decide what to do about memory.
- **FR4** — The two answers are presented symmetrically. No default, no
  fallback, no safe option.
- **FR5** — Under with-commit, memory bodies and the handoff files are written
  as if the pending changes have already landed.
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

**without-commit** — today's text verbatim.

**with-commit** — same status block and the same summarize → blockquote →
approve gate, then:

- write the approved summary to `<msgfile>` and **nothing else**;
- do **not** write `<trigger>` — naming it explicitly, because writing it is
  the standalone commit this mode exists to avoid;
- state what happens instead: the parent commit's pre-commit hook finds the
  approved summary, commits the submodule, and stages the new memory pointer
  into the same commit;
- write the summary file only after every memory edit is final, or the
  freshness check stales it and the commit aborts.

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

Both skills gain a new first step: decide the answer from the request, no tool
calls, two options of equal weight, no default. Existing steps renumber. The
probe invocation becomes `handoff-memory-probe <answer>` /
`handoff-precompact-probe <answer>`.

Content rules the answer feeds:

1. Memory is written as landed under with-commit — present-tense truth, which
   is the standing rule regardless.
2. `handoff-todo.md` carries no "commit the work" / "push the branch" item
   under with-commit. (`handoff-task.md` already excludes commit status by
   template — DESIGN.md, 2026-06-24.)

precompact gets one more rule, and it is load-bearing: **under with-commit the
commit must land before `./.claude/autocompact` is written.** Writing
`autocompact` then asking for commit approval ends the turn; `Stop` arms the
compaction, and it runs instead of the commit. Same shape as the existing
"never in the same turn as a question the directive requires".

**The skills never commit.** `with-commit` is a statement about what the turn
does around the skill, not an instruction to the skill to run git.

## Rejected alternatives

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

- with-commit × dirty memory → summary path present, trigger path **absent**
- without-commit × dirty memory → both paths present (existing assertions)
- both modes × clean memory → silent
- no argument → exit 2, usage on stderr
- unknown argument (`--with-commit`, `commit`, `yes`) → exit 2
- two arguments → exit 2
- precompact: composed memory-then-SDD ordering holds under both modes
- both `bin/` shims forward the argument

The load-bearing assertion is a negative — "with-commit output does not name
the trigger file". Per `feedback_mutation_check_negatives` it is verified by
removing the branch and watching that test go red, not by observing it pass.

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
