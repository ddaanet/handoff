# Deliverable Review: 2026-09-04-checkpoint-null-no-task-file

**Date:** 2026-09-08
**Methodology:** edify `deliverable-review` (two-layer: delegated per-file + interactive cross-project)
**Baseline:** `plans/2026-09-04-checkpoint-null-no-task-file/outline.md` (this job has no `design.md`)
**Range:** `e370aed..HEAD` (Item 0.1 through the TDD audit)

**Counts: 1 Critical, 4 Major, 18 Minor.**

The change itself is sound and conformant: every deliverable the outline names
landed, every named deletion is gone, `just precommit` is green (218 passed, 11
deselected), and the docs carry the change in all five places the outline
requires. The Critical is a pre-existing ordering hazard that decision 3's eager
unlink converted from "writes something recoverable" into "deletes the task
frame". Four of the five top findings converge on one seam: `todo`'s `clear`
action, which is the least documented, least tested, and most destructive arm of
the union.

---

## Inventory

| Type | File | +/- |
|---|---|---|
| Code | `scripts/checkpoint.py` | 106/87 |
| Code | `scripts/bash-post.sh` | 45/2 |
| Test | `tests/test_checkpoint.py` | 381/342 |
| Test | `tests/checkpoint.bats` | 119/1 |
| Agentic prose | `skills/handoff/SKILL.md` | 9/10 |
| Agentic prose | `skills/precompact/SKILL.md` | 9/3 |
| Human docs | `CLAUDE.md` | 33/13 |
| Human docs | `docs/design.md` | 37/13 |
| Human docs | `docs/changelog/2026-09-07-the-payload-names-its-actions.md` | 116/0 (new) |
| Human docs | `docs/changelog/2026-07-27-content-null-is-a-no-op.md` | 9/0 |
| Human docs | `docs/changelog.md` | 1/0 |

**Design conformance:** all IN-scope files touched; no OUT-scope file touched.
`tests/checkpoint.bats` is unspecified but justified excess — the outline's IN
list names `scripts/bash-post.sh` without naming its test file, and all five
added rows cover it.

---

## Critical Findings

### C1 — a failed `todo` edit destroys the task frame, unrecorded and unreported

**`scripts/checkpoint.py:505-509`** (ordering); `:395-399`, `:345-347` (the
`err()` sites). Axis: functional correctness / robustness. **Verified
independently in this session**, and by the delegated code review.

`main` applies the task before the todo. `apply_todo` can `err()`, which exits 2
immediately — before `write_manifest` and before `compose_sentinel`. So the task
half has already been applied to disk, and nothing records it: no manifest ⟹
`bash-post.sh` never fires ⟹ the change is never staged and never reported on
either channel.

Reproduced against a clean checkout:

```
task: {"action": "clear"}
todo: {"action": "edit", "old_string": "nope", "new_string": "y"}
pre-existing .claude/handoff-task.md holds "IMPORTANT TASK FRAME"

→ handoff-checkpoint: todo.old_string: edit requested but
  .claude/handoff-todo.md does not exist                    exit=2
→ task file exists?  NO
→ manifest exists?   NO
→ sentinel exists?   NO
```

The write half of this is pre-existing. What decision 3 adds is the delete half:
`clear` now unlinks eagerly, so a payload whose *todo* half is malformed removes
the task frame while reporting an error that names only `todo.old_string`.

**Why Critical rather than the delegated review's Major.** The severity rubric
puts data loss at Critical, and this is reached without any malformed shape — a
non-matching `old_string` is a routine agent error, covered by three tests of its
own, and the skill bodies invite the `edit` action without stating its
preconditions (see m13). The combination `task: clear` + `todo: edit` is exactly
a wrap-up where the task finished and the list has leftovers. The outcome — a
task frame that does not survive into the next session, with the checkpoint
reporting something else — is the 2026-09-02 incident this whole job exists to
prevent, reached through a different door.

Recoverable only if a prior checkpoint staged the file, in which case it shows as
an unstaged deletion in `git status` with no explanation.

**Cheapest remedy consistent with the design:** hoist `apply_todo`'s two `edit`
preconditions (file exists; `old_string` present and unambiguous) ahead of
`apply_task` — they are the only apply-time failures. Alternatively write the
manifest for whatever was applied before `err()` exits, so the mutation at least
reaches `bash-post.sh`.

No test covers it: `test_todo_edit_old_string_absent_errors` (`:806`) and
`test_todo_edit_requested_file_missing_errors` (`:843`) both send `task_clear()`
against a repo with no task file, so neither can observe the deletion.

---

## Major Findings

### M1 — `todo: {"action": "clear"}` has zero coverage anywhere in the repo

**`tests/test_checkpoint.py`** (absent), `scripts/checkpoint.py:386-390` (the
uncovered branch). Axis: coverage. **Mutation-verified.**

The spelling `{"action": "clear"}` appears exactly once in `test_checkpoint.py` —
inside `task_clear()`'s body (`:117`). There is no `todo_clear()` factory beside
`task_clear()`, `todo_keep()` and `todo_edit()`, and no test builds the payload
literally. `tests/checkpoint.bats` does not exercise it either.

Mutation check — replacing the whole branch with a no-op:

```python
if action == "clear":
    return []  # MUTANT: never removes, never records D
```
→ **128 passed.** The branch is dead to the suite.

For contrast, three sibling mutations on the same two functions all discriminate:
`apply_task`'s never-existed guard reds 4 tests, `apply_todo`'s conditional `D`
reds 1, and `_todo_edit_strings`' type check reds 2. Coverage is otherwise good,
which is what makes this a real gap rather than general laxness.

The outline specifies this arm (`"todo": … | {"action": "clear"}`) and specifies
its tests ("`{"action": "clear"}` against a pre-existing file removes it and
records `D`; against a never-existed file removes nothing and records no `D`" —
written to keep `apply_task` and `apply_todo` aligned). Those rows exist for
`task` (`:618`, `:642`) and were never mirrored for `todo`.

### M2 — neither skill body says which action a boundary with no todo content sends

**`skills/handoff/SKILL.md:81,104-109`**, **`skills/precompact/SKILL.md:49,80-84`**.
Axis: determinism / actionability. From the delegated prose review; verified
against the dispatch.

Step 3 gives only the positive branch ("*if so*, draft the todo content"). The
explanatory paragraph names the negative branch for `task` only ("*for `task`,
this is how a boundary with nothing to carry says so*"). For `todo`, nothing says
which action to send when there is no todo content — and the two candidates have
opposite effects (`checkpoint.py:382-390`):

- `{"action": "keep"}` — returns `[]` without touching the file, not even to stat
  it. Reading: "this call says nothing about the list." FR4-correct, and the
  direct heir of the deleted `null` no-op rule.
- `{"action": "clear"}` — unlinks and emits `D`. Reading: "no open items remain."

One preserves a possibly-stale list into the next session; the other deletes an
open remainder. Preserving a stale list is the exact defect class this change
eliminated for `task`; the union removed the shared *spelling*, but the missing
*decision rule* leaves the ambiguity one level up, in the producer.

Concretely: one clause tying `keep` to "this call says nothing about the list"
and `clear` to "every item landed", or an `if not` branch on the step-3 bullet.

**M1 and M2 are the same seam.** The arm no prose tells an agent when to use is
the arm no test exercises — and per C1 it is also the destructive one.

### M3 — action objects and the payload silently ignore unknown keys

**`scripts/checkpoint.py:274`, `:300`** (`.get("action")` with no key-set check);
`read_payload` (`:91`) at the top level. Axis: error signaling / conformance to
decision 1. **Verified.**

```
"task": {"action":"clear","content":"IMPORTANT UNSAVED"}     → exit 0, file removed, content discarded
"todo": {"action":"keep","content":"## Remaining\n\n- x\n"}  → exit 0, content discarded
{…, "tasks":"oops"}                                          → exit 0, key ignored
```

Decision 1's whole argument is that a mistyped *action* becomes a named schema
error rather than silently writing the wrong thing (`{"action": "emty"}` is the
outline's own example). A mistyped or superfluous *key* still does not. The
payload retains a shape that quietly does something other than what it says —
the defect class the job was opened to close.

The likeliest agent errors do fail loudly: the old `{"file_path":…,"content":…}`
shape hits `task.action: required`, and `{"action":"write","content":…}` hits
`must be "clear", got "write"`. But the second of those is one step from silent
loss: an agent that reads `must be "clear", got "write"` and corrects only the
`action`, leaving `content` in place, destroys the frame and is told nothing.

Rejecting unknown keys in the two action objects is a few lines and closes the
class properly. The slice 1 code review routed this to Phase 3/4 as a question;
neither phase answered it.

**Elevated from the delegated review's Minor** because the outcome is silent loss
of the artifact the plugin exists to preserve, and the route to it runs through
the validator's own error message.

### M4 — `task.action: required` names no vocabulary, and it is the skew message

**`scripts/checkpoint.py:278`, `:309`**. Axis: error signaling. **Verified.**

Every other message in the union names what to write instead — `task: must be a
content string or {"action": "clear"}, got null`; `todo.action: must be "clear",
"keep" or "edit", got "emty"`. The missing-`action` branch says only `required`.

That branch is not hypothetical: it is what the **old payload shape** hits, which
is precisely what a live session emits between slice 1 landing and a
`/reload-plugins` — the producer/consumer skew the outline's Verification section
calls out by name. The outline argues the rejection is "loud, which is the right
failure". Loud it is, but an agent reading `task.action: required` learns neither
that a bare string is now the content form nor that `clear` is the only legal
action. Both facts are one f-string away and both appear verbatim in sibling
messages.

This is live right now: the handoff task frame for this very job carries a
warning that a post-`/clear` session may compose the retired shape, and tells the
reader to send the union directly or `/reload-plugins`. That warning exists
because the error message does not carry it.

`tests/test_checkpoint.py:437-443` pins the branch with `reason="action:
required"` — a substring any improved message still satisfies, so the suite does
not obstruct a fix, but nothing requires the vocabulary either.

---

## Minor Findings

### Schema and error signaling

- **m1 — `{"action": null}` reports `required`, conflating explicit null with an
  absent key.** `checkpoint.py:277-278`, `:308-309`. **Verified.** `{"action":
  null}` and `{}` produce the identical `task.action: required`. This is the
  conflation the job's own premise argues against (decision 2 makes `null` and an
  absent key each a *named* error at the top level). The correct idiom lives 30
  lines below in `_todo_edit_strings`, which checks `if key not in todo` and then
  types the value — so `{"old_string": null}` gets `must be a string, got null`
  while an absent one gets `required for {"action": "edit"}`. Applying the same
  two-step to `action` is mechanical. Left deliberately by the slice 1 code
  review.
- **m2 — non-string `action` values render as Python reprs.** `checkpoint.py:279`,
  `:310`. **Verified:** `{"action": true}` → `got "True"`; `{"action": 5}` → `got
  "5"`. `True` is not a JSON spelling, and the file owns `_json_type()` for
  exactly this — neighbouring diagnostics say `got boolean` / `got number`.
- **m3 — `apply_todo` writes an empty body to disk before unlinking it.**
  `checkpoint.py:391-403`. `apply_task:361` tests `is_empty_body(content)` before
  writing and never creates the file; `apply_todo` writes first and reads back.
  The read-back is right for the `edit` route (the result exists only on disk),
  but the `write` route has the content in hand. As written, `apply_task`'s own
  docstring claim — "an empty body is never written first" — is true of itself and
  false of its sibling.
- **m4 — a whitespace-only body is written as content.** `checkpoint.py:361` via
  `_checkpoint_lib.py:30-34`. `"task": "   "` → exit 0, `W` line, a 3-byte file
  that passes `load-handoff.sh`'s non-empty gate. Pre-existing and explicitly
  **OUT** of the outline's scope (`is_empty_body`); noted only because the union
  makes a bare string the ordinary content form, putting a hand-typed `" "` one
  keystroke closer than the old `{"content": " ", "file_path": …}` did.

### `bash-post.sh`

- **m5 — a handoff root that is not a git repository now reports a failure at
  every checkpoint.** `bash-post.sh:54-68`. **Verified:** a non-repo root emits
  `staged 0, deleted 0; failed to stage: .claude/handoff-task.md` on both channels
  plus git's raw `fatal: not a git repository` on stderr, where it previously read
  `staged 0`. The report is *true* — nothing was staged — but decision 4's
  reasoning is that "a failed `git add` is a real defect", and in a non-repo it is
  the environment, not a defect. The guard distinguishes the benign per-path case
  (`D` for a path never in the index) but not the whole-run case, so it re-reports
  once per manifest line. One `git rev-parse --git-dir` at the top would separate
  them. Named as an accepted consequence by the Phase 2 review; no test row covers
  it (all nine `bash-post` rows `git init` first).
- **m6 — the "git's stderr now reaches the user" comment is unverified.**
  `bash-post.sh:77-78`. For a hook exiting 0, Claude Code generally surfaces
  stderr only in debug/transcript mode. What demonstrably carries the failure to
  both audiences is the named path appended to `summary` and `agent_ctx`, which
  the bats rows pin; `grep -q 'index.lock' "$err"` proves git's message reaches
  the *process's* stderr, not that anyone reads it. Worth downgrading the comment
  to what is demonstrated. (Not verified by this review either.)
- **m7 — the manifest is consumed even when every path failed to stage.**
  `bash-post.sh:70`. `rm -f "$manifest"` is unconditional, so a stranded
  `index.lock` costs the staging permanently with no retry. Consistent with the
  item's report-only design, but the agent-facing channel names the path and says
  nothing about what to do, while the "leave them staged" clause is suppressed.
  One clause (`— re-stage with git add -f`) would close it.

### Tests

- **m8 — `test_todo_edit_requested_file_missing_errors` names no field.**
  `tests/test_checkpoint.py:843-857`. Asserts `returncode == 2` and `"does not
  exist" in result.stderr` only. Its two siblings (`:806`, `:825`) both assert
  `"old_string" in result.stderr` alongside their reason. `does not exist` is
  distinctive enough today that the row is not vacuous, but it is the odd one out
  in a namespace carrying five distinct messages, and the discipline slice 3's
  review established is to pin field *and* reason. Pre-existing and frozen by the
  runbook.
- **m9 — `test_task_and_todo_both_written_manifest_lists_both` does not bound the
  manifest.** `tests/test_checkpoint.py:962-984`. Two membership assertions over
  `.splitlines()`, no `len(manifest) == 2`; a regression appending a spurious
  third line passes. The `clear`/never-existed rows compensate with broad absence
  assertions, so this is the one positive row where nothing bounds the list.
- **m10 — `tests/checkpoint.bats` uses jq `test()` (regex) on dotted paths.**
  `:394, 396, 417, 419, 427, 429`. `test("failed to stage: .claude/…")` treats
  each `.` as "any character". Strong enough to have redded under all three
  bash-post mutations, so cosmetic — `contains(…)` says what is meant.
- **m11 — `handoff_payload()` is the last cross-file coupling to the union's
  spelling.** `tests/checkpoint.bats:211-213` hardcodes `task:{action:"clear"},
  todo:{action:"keep"}` outside the Python factories, with nothing in either place
  pointing at the other. A cross-reference comment costs one line.

### Documentation

- **m12 — `D2`/`D3` are cited in shipped code and resolve nowhere durable.**
  `scripts/checkpoint.py:352`, `:371`, `tests/test_checkpoint.py:544`. **Verified:**
  `D1`–`D4` are defined only in `plans/…/runbook.md:20-23`, a write-time artifact
  that per `CLAUDE.md`'s `plans/` rule is never revised; `docs/design.md` has zero
  matches, while `FR5`/`FR6`/`FR7` cited beside them all resolve there. The same
  reference-rot the design/changelog convention exists to prevent.
- **m13 — the skill bodies omit the `edit` action's preconditions.**
  `skills/handoff/SKILL.md:107`, `skills/precompact/SKILL.md:82-83`. The validator
  errs when the file is absent, and `apply_edit` errs when `old_string` is absent
  or ambiguous. All three are tested; all three cost a round trip the prose could
  avoid. Bears directly on C1, which is reached through exactly this error.
- **m14 — FR6 is no longer stated in either skill body.** The deleted sentence
  carried it obliquely; the replacement names `clear` as the only removal route,
  but `apply_task`/`apply_todo` also remove a file whose drafted body is empty
  under `is_empty_body`. An agent drafting a headings-only todo gets a removal it
  did not ask for and was not told to expect. The outcome is correct; the prose
  does not promise it.
- **m15 — `CLAUDE.md:821-824` narrates its own prior wording.** "It does **not**
  cover `write-stage.sh` or `bash-post.sh`, which this sentence used to claim" —
  self-referential commentary inside a present-truth document. The substantive
  correction is real and verified; elsewhere CLAUDE.md narrates *code* history,
  which is a different thing.
- **m16 — `CLAUDE.md:815-821` lists the union's rejection rows but none of its
  behavioral rows.** `{"action": "clear"}` removing a pre-existing file and
  recording `D`, the never-existed case, and `{"action": "keep"}` leaving the list
  alone all exist (`:618`, `:642`, `:859`, the last carrying a load-bearing
  negative) and go unclaimed while a dozen schema-error rows are named
  individually.
- **m17 — the task-file location rule is now asymmetric.**
  `skills/handoff/SKILL.md:142` vs `:194`. The rule was deleted for
  `handoff-task.md` while the path was added to its template header, and the
  `handoff-todo.md` equivalent survives. Defensible — the todo is agent-editable
  (FR4) and the task is not — but it reads as an oversight, and the task header
  now names a path the agent can neither write nor supply.
- **m18 — the changelog names "one of two routes" and not the other.**
  `docs/changelog/2026-09-07-the-payload-names-its-actions.md:61-63`. Recoverable
  from `bash-post.sh:33-40` (a `git reset` since the last checkpoint, or a
  hand-written file, leaves a real removal targeting an untracked path) but not
  from the durable record alone.

---

## Gap Analysis

| Outline requirement | Status | Reference |
|---|---|---|
| `validate_task` replaced; accepts string or `{"action":"clear"}`; rejects `null`; key required | Covered | `checkpoint.py:265-283` |
| `validate_todo` collapses key-sniffing into an `action` dispatch | Covered | `checkpoint.py:287-313` |
| `_todo_file_path`, `has_content`/`has_old`/`has_new`, `file_path` all deleted | Covered | 0 occurrences each |
| `apply_task`/`apply_todo` unlink-if-present, existence sampled first, `D` only on a real removal | Covered for `task`; **`todo`'s `clear` arm untested** | M1 |
| `bash-post.sh:36` drops `2>/dev/null`, guards the benign case with `git ls-files` whose status is read | Covered (sole remaining occurrence is in a comment) | `bash-post.sh:54-58` |
| Delete `test_task_content_null_no_file_path_noop` and `test_task_file_path_content_null_noop` rather than inverting | Covered — 0 occurrences | — |
| Add: `null` rejected by name per field; key absent per field; unknown action; clear against pre-existing / never-existed; `keep` leaves alone | Covered for `task` and `keep`; **`todo` clear missing** | M1 |
| Payload factories route every test payload | Covered — 0 literal `"task": {` spellings | `test_checkpoint.py:112-129` |
| Both SKILL.md bodies name the four actions; `file_path`, `null`-rule and path interpolation gone | Covered; **`todo` negative branch unstated** | M2 |
| `docs/design.md` takes a superseding pointer; FR5 restated in action terms; magic-string alternative recorded | Covered | `design.md:215-234` |
| New changelog entry leads with the incident, carries five rejected alternatives | Covered — all five present | changelog entry `:65-104` |
| Changelog index line in the same pass | Covered — format and length in family with siblings | `changelog.md:11` |
| Superseded blockquote on `2026-07-27-content-null-is-a-no-op.md`, scoped | Covered — explicitly "scoped to the remedy, not the diagnosis" | — |
| `CLAUDE.md` Layout + Testing sections updated | Covered; test count claim (128) verified accurate | m15, m16 |
| `just precommit` green | **Verified** — 218 passed, 11 deselected, exit 0 | — |
| Version bump for delivery | **Open** — my human partner's call, unchanged by this review | — |

---

## Process Findings

Not deliverables; carried from the TDD audit's two open items, both now settled
with evidence.

### P1 — `phase-1-corrector.md:168-173`'s mutation evidence does not reconstruct

The report claims that "mutating `validate_root` to fall back to `Path.cwd()`"
reds `test_drifted_cwd_writes_injected_root_never_cwd` (plus
`test_handoff_root_names_non_directory_refuses`). Both spellings tested:

| Mutation | Result |
|---|---|
| **As written** — `os.environ.get("HANDOFF_ROOT","") or str(Path.cwd())` | reds `test_handoff_root_unset_refuses` **only** — the named test stays green, and so does the other named test |
| **As the audit restates it** — `root = str(Path.cwd())`, unconditionally | reds all three, including the drift test |

The report's *conclusion* is correct — the drift test does discriminate — but not
by the mutation it records, and the fallback it describes cannot red that test at
all, since the test sets `HANDOFF_ROOT`. The audit's reading is right. This
matters because `plans/` reports are write-time records a later session trusts
instead of re-running: an unreproducible mutation reads as coverage that is not
there.

### P2 — there is no stated convention for correcting a write-time report

`CLAUDE.md:720-723` makes `plans/` write-time records "not revised as the code
moves past them", and `docs/changelog/`'s bullet states its correction form (a
`> **Superseded <date>**` blockquote scoped to what changed). `plans/` has no
equivalent — yet corrections happened this run, and the form invented for them is
good: `> **Corrected at review, <date>.**`, quoting the original text, naming
what was wrong, showing the evidence, and stating that nothing was lost
(`item-1-2-red.md:98`, `:130`).

That form is a direct sibling of the changelog's and deserves the same one-line
statement in `CLAUDE.md`'s `plans/` bullet, or the next session invents a
different one. Resolving P1 will need it immediately.

---

## Summary

**1 Critical, 4 Major, 18 Minor**, plus 2 process findings.

The delivered change conforms to its outline on every specified point, and the
documentation pass is unusually complete — all five contract locations updated in
one pass, the superseded blockquote correctly scoped, the CLAUDE.md test-count
claim accurate, and a pre-existing false coverage claim corrected along the way.

What the review found clusters, and the cluster has a shape: **`todo`'s `clear`
action is the weakest point of the delivery.** No prose says when to send it
(M2), no test exercises it (M1, mutation-proven), and via the ordering hazard it
is the action that silently destroys the task frame (C1). M3 and M4 are the two
places where decision 1's "name the error rather than guess the intent"
principle was applied to action *values* but not to the surrounding key set or to
the one message an out-of-date producer actually hits.

C1 is the only finding that loses data. M1 and M2 are cheap and belong together.
M3 and M4 are each a few lines. The 18 minors are genuinely minor; several (m4,
m8) are pre-existing and explicitly out of the outline's scope.

Two layers reviewed independently and converged on M1 and C1 from different
directions — the delegated code review by reading `main`'s ordering, this session
by mutation — which is the strongest evidence in the report.

---

## Verification method

Every empirical claim above was run in this session against a clean checkout and
its output quoted: the payload probes (`HANDOFF_ROOT=<tmp> python3
scripts/checkpoint.py` with real payloads), the C1 reproduction, the four
mutations on `checkpoint.py`, the two `validate_root` mutation spellings, and
`just precommit`. Every mutation was applied from a verified backup and restored;
`git diff --quiet` confirmed clean after each, and the working tree is unmodified
by this review.

Not verified: m6 (how the harness surfaces a PostToolUse hook's stderr), and M2's
divergence claim, which is derived from reading the prose against the dispatch
rather than from observing two agents split.

Layer 1 reports: `deliverable-review-code.md`, `deliverable-review-prose.md`.
