# Phase 3 checkpoint review — Item 3.1, both wrap-up SKILL.md bodies

Reviewed at `b42acec`. Both jobs in one pass: item review (contract
correctness) and phase-boundary correction. `plugin-dev:skill-development`
invoked and applied for the skill-conventions half. All fixes applied; not
committed.

**Verdict: PASS with three fixes applied.** No UNFIXABLE.

## Verification performed

Every documented payload shape was **run** against `scripts/checkpoint.py`
(not reasoned about), at both boundaries, against a fixture with a
pre-existing task file and todo file:

| shape | result |
| --- | --- |
| `task` string, `todo` string | rc 0, manifest `W`/`W` |
| `task {"action":"clear"}`, `todo {"action":"keep"}` | rc 0, manifest `D` task only; todo untouched |
| `todo {"action":"clear"}` | rc 0, manifest `D` todo |
| `todo {"action":"edit",…}` | rc 0, manifest `W`, first occurrence replaced |
| `task: null` | rc 2 — `task: must be a content string or {"action": "clear"}, got null` |
| `todo: null` | rc 2 — `todo: must be a content string or an object naming an action, got null` |
| `task` key absent | rc 2, names `task` |
| `todo` key absent | rc 2, names `todo` |
| `task {"action":"keep"}` | rc 2 — `task.action: must be "clear", got "keep"` |
| `task {"action":"edit",…}` | rc 2 — `task.action: must be "clear", got "edit"` |
| `rename` under `precompact` | rc 2 — `rename: forbidden when skill is "precompact"` |

Word budgets after the fixes, by the runbook's own command:
**handoff body 1957** (was 1968; 43 words of headroom against the ≤2000
convention), **precompact body 1069** (was 1054).

`just precommit` green after the fixes: **164 bats, 218 pytest passed +
11 deselected** — the counts the dispatch names.

`grep` confirms no surviving `file_path` or "nothing to say" anywhere under
`skills/`, and that only `handoff/SKILL.md` and `precompact/SKILL.md`
mention `task`/`todo` payload keys — `autoname`, `restart` and `pending`
carry neither, as the schema requires.

## Findings and fixes

### 1. MAJOR — `precompact/SKILL.md` dropped the `task`/`clear` clause the item requires

The runbook states of the replacement: *"It must say what `{"action":
"clear"}` does for `task` in one clause, since that is the case where an
agent previously reached for `null` and got silence."* `handoff/SKILL.md`
carries that clause; `precompact/SKILL.md` did not — it said only that
`{"action": "clear"}` "removes that file", which names the mechanism without
naming the case.

This is not covered by precompact's deference to handoff. That deference is
scoped to "the full templates, the rules behind them, and the seam", and is
conditional ("Read that file when the rules matter"). A precompact agent
composes its own heredoc from its own body and may never open
`handoff/SKILL.md`. The defect this whole job fixes — an agent with nothing
to carry reaching for the wrong spelling — is reachable identically at the
compact boundary. `skills/precompact/SKILL.md:80-84` now states it, in
wording parallel to handoff's, which also reduces drift between the two
copies (lead 4).

### 2. MINOR — `{"action": "edit"}` was not marked `todo`-only, in either file

Both paragraphs attached the parenthetical `(todo only)` to `{"action":
"keep"}` alone. By contrast that reads as `edit` being available on `task`,
which the validator rejects (`task.action: must be "clear", got "edit"`,
run above). The heredoc's `task` line shows the true union, but the prose is
what states the rule, and an over-claim in an agent-facing directive is
worse than silence — the reader has no other source.

Both files now say `keep` and `edit` are "both `todo` only" in one clause,
which also costs fewer words than two parentheticals would.

### 3. MINOR — vestigial task-file location rule (outside the runbook's named sites)

`skills/handoff/SKILL.md` "Task file rules" carried:

> `- No location other than ./.claude/handoff-task.md — the hook reads this exact path.`

That rule existed because the agent used to compose `file_path`. With
`file_path` gone from the payload the agent cannot express a location at
all — `apply_task` builds the path from `HANDOFF_ROOT` — so the rule
instructs nobody. It is exactly the absence-guard
`remove-cleanly-no-vestigial` (in this job's own recall artifact) says not
to leave behind, and it was made dead by this item. Removed.

The sibling rule in "Todo file rules" (`No location other than
./.claude/handoff-todo.md`) is **kept deliberately**: the agent writes that
file directly all session under FR4, and `write-stage.sh` matches on the
resolved path, so it still has a subject.

**Flagged explicitly because it is outside the runbook's named lines** (the
heredoc and the paragraph below it), though inside an IN file and caused by
this item. Trivially revertible if the orchestrator judges it Phase 4's.

## Weighed and left alone

**The `…` in `"old_string": "…"` (lead 3).** It *can* be pasted through as a
literal JSON value, but the failure is loud and self-naming — run above:
`todo.old_string: not found in <path>`, rc 2, nothing written. More
decisively, it is not an outlier in its own line: `"task content"` and
`"todo content"` on the same two lines are also unbracketed placeholders
that are valid JSON, and *those* paste through **silently**, writing a file
whose body is the placeholder. The ellipsis is the safer of the two forms,
not the riskier one. Spelling it `"<text to replace>"` would match the
`"<session title>"` convention but would single out the least dangerous
placeholder on the line while leaving the more dangerous ones, so it buys
nothing. The file's own convention is the baseline, per the dispatch.

**The `<…|…>` alternation with JSON-object alternatives (lead 2).** It reads
unambiguously: the outer `<…>` is the alternation wrapper the file already
uses for `continue` and `compact`, and each alternative is a complete,
self-delimiting JSON value — a quoted string or a braced object. Every shape
an agent would produce from it was run above and accepted. No change.

**What the rewrite dropped (lead 5).** The retired sentence — "the checkpoint
decides absence from content, not from a wipe" — was rationale for why the
form exists, and nothing load-bearing went with it. The reader's act is
covered: nothing to carry ⟹ `{"action": "clear"}`, stated in its own clause
in both files now. The empty-body route to removal is deliberately unstated
and should stay unstated: it is not an act the agent chooses, it is what the
checkpoint does to a draft that turned out to be headings only, and naming
it would offer a second spelling for a case that already has one. Per
`directive-states-acts`, mechanism the reader cannot act on gets verified
and narrated back.

**`skill-development` conventions.** Both bodies stay within the 1500–2000
word target with headroom. The new prose introduces no second person, keeps
the imperative/declarative register of the surrounding text, and adds no
content that belongs in `references/` — it is the payload contract, which is
core procedure. Frontmatter descriptions untouched (out of scope, and both
already carry concrete trigger phrases in third person).

## Files changed by this review

- `/Users/david/code/handoff/skills/handoff/SKILL.md`
- `/Users/david/code/handoff/skills/precompact/SKILL.md`

Working tree carries only these two edits plus this report. No commit.
