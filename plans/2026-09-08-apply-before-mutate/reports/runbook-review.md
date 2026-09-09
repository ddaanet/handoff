# Runbook Review: nothing is written until both halves resolve

**Artifact**: `plans/2026-09-08-apply-before-mutate/runbook.md`
**Design**: `plans/2026-09-08-apply-before-mutate/outline.md` (proofed
item by item 2026-09-10 — treated as settled)
**Triage**: `plans/2026-09-08-apply-before-mutate/classification.md`
**Recall**: `plans/2026-09-08-apply-before-mutate/recall-artifact.md`
(all ten listed memory files read)
**Requirements source**:
`plans/2026-09-04-checkpoint-null-no-task-file/reports/deliverable-review.md`
§C1, §m3, remedy (b)
**Date**: 2026-09-10
**Mode**: review + fix-all

## Summary

The runbook is faithful to the outline, its enumerations re-derive correctly
against the code, and every requirement in reach traces to an item. Two Major
defects were load-bearing: one mutation check predicted a red that cannot
happen (the row it names stays green under the mutation, so the check would
have been recorded as evidence while proving nothing), and one piece of prose
the change falsifies — `CLAUDE.md:614` — was not in any item's file list,
because the outline's "nothing else in it moves" reads `CLAUDE.md` as one
bullet. Both are fixed. No decision in the outline was altered; the two places
where the runbook now departs from it are recorded in the runbook's own
"Corrected against the outline" section, which grew from one item to two.

**Overall Assessment**: Ready.

## Requirements Coverage

| Requirement | Phase | Items | Coverage | Notes |
|---|---|---|---|---|
| FR2 — violation exits non-zero naming the field | 1 | 1.1 | Complete | the three `err()` sites move ahead of every mutation with field names and message text intact; `edited_body` keeps `path` in its signature so both messages stay byte-identical |
| FR4 — a call silent about the scratch list leaves it alone | 1 | 1.1 | Complete | `keep` short-circuits ahead of the resolver; the regression guard is now named (`test_todo_keep_leaves_pre_existing_list_alone`), which it was not before |
| FR5 — the task/todo union's write semantics | 1, 2 | 1.1, 2.1 | Complete | observably unchanged; four existing `edit` rows extended in place |
| FR6 — an empty body is removed, the removal staged | 1, 2 | 1.1, 2.1 | Complete | the new `edit`-to-empty row is the only route with no coverage today; mutation (b) is its evidence |
| FR7 — everything written reaches the manifest | 1, 2 | 1.1, 2.1 | Complete | `write_manifest` stays unconditional; the positive row's exact-two-lines assertion is what pins both halves reaching it, and mutation (c) now discriminates it |
| NFR1 — no git, no tmux | 1 | 1.1 | Complete | no new subprocess, no new import |

FR1, FR3, FR8, FR9, FR-G, FR-H, NFR2 and NFR3 are out of the change's reach.
That was true of the runbook before this review but unstated, so an absent row
read the same as an oversight; a sentence under the table now names them.

Deliverable-level cross-check against the outline's "Per-file changes": all
five `checkpoint.py` bullets, all five `test_checkpoint.py` rows and all four
doc targets map to an item. No unmapped deliverable.

## Review Findings

### Critical Issues

None.

### Major Issues

1. **Mutation check (c) predicted a red that cannot occur**
   - Location: Item 1.1, "Mutation checks", clause (c)
   - Problem: it made the shared resolver emit `D` unconditionally on the
     removal route and expected
     `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` to
     red. That row's task half is `clear` against a **pre-existing** task
     file, so the removal route emits `D` with the existence guard or without
     it, and its todo half takes the write route untouched. The manifest is
     byte-identical under the mutation and the row stays green — the check
     would have been performed, observed green-where-red-was-predicted or
     (worse) recorded as passing, and the positive row would still have no
     evidence. The row is characterisation of behaviour that is green today,
     so this mutation was its *only* evidence.
   - Fix: split into (c) and (d). (c) now drops the task plan's manifest lines
     from `main()`'s concatenation, which reds the row on its exact-two-lines
     assertion — the second claim the rename adds — with the honest note that
     it will not red alone. (d) keeps the existence-sampling mutation, aimed
     at the four never-existed rows it actually discriminates (named with line
     numbers), and states explicitly that the positive must stay green under
     it and why.
   - **Status**: FIXED

2. **`CLAUDE.md:614` is falsified by the change and no item names it**
   - Location: Item 2.1, `CLAUDE.md` paragraph
   - Problem: the `_checkpoint_lib.py` bullet says `is_empty_body` is "Shared
     by `checkpoint.py` (after a Write/Edit it just applied) and
     `write-stage.sh` …". Inverting exactly that is the point of m3 — after
     the change the checkpoint tests a resolved body *before* applying
     anything, on both halves. The item scoped its `CLAUDE.md` edit to the
     `scripts/checkpoint.py` bullet alone, carrying the outline's claim that
     the bullet "names no functions, so nothing else in it moves". That claim
     is true of *that bullet* and false of the file.
   - Fix: item 2.1's `CLAUDE.md` paragraph became three numbered sites, the
     second being `:614`, with `write-stage.sh`'s half of the sentence named
     as untouched so the executor does not over-edit. Recorded as correction 2
     in the runbook's "Corrected against the outline" section rather than
     silently diverging from a proofed design.
   - **Status**: FIXED

3. **The guarantee was stated wider than what lands**
   - Location: runbook header; propagated into item 2.1's `docs/design.md`
     instruction
   - Problem: "every failure the checkpoint raises itself happens while
     resolving" is false of `compose_sentinel`'s read-back `err()`
     (`checkpoint.py:503-509`), which fires after both halves are applied and
     after `write_manifest`. It is not a defect — the manifest is already
     written, so the mutation is recorded and staged — but item 2.1 instructs
     the executor to write the guarantee into `docs/design.md`, which is
     present-tense current truth. An unscoped sentence there would be false on
     the day it was written and would rot silently.
   - Fix: the header now states the guarantee's subject as the two halves and
     their manifest, names the sentinel read-back beside the `OSError` as
     outside it, and says why it is not a counterexample. Item 2.1's
     `docs/design.md` instruction is bound to the same scope.
   - **Status**: FIXED

4. **The rename enumeration claimed completeness while omitting two sites**
   - Location: Item 1.1, "The rename reaches every live citation"
   - Problem: it read "the two definitions and both call sites", omitting
     `apply_edit`'s own definition (`:378`) and its call inside the todo half
     (`:440`). Both are covered in practice by the prose above it, but an
     enumeration that says "every live citation" and lists a short set is the
     exact failure mode `spec-enumerations-need-rederiving` describes:
     conformance passes clean against a list that is wrong.
   - Fix: rewritten as three definitions and three call sites, each with its
     line number. Re-derived by grep at review time, not copied from the
     runbook — the live set is `checkpoint.py` `:364`, `:378`, `:392`, `:411`,
     `:416`, `:420`, `:440`, `:546-547`; `tests/test_checkpoint.py:538`;
     `docs/design.md:240`. Everything else is under `plans/` or
     `docs/changelog/2026-09-07-…:53`, both frozen. That matches the runbook's
     coverage exactly once the two omissions are added.
   - **Status**: FIXED

### Minor Issues

5. **`CLAUDE.md`'s test count moves with the new row** — the Testing section
   bullet (`:802`) reads "(128 tests)"; the file collects 138 today and this
   change adds one. Fix: added as site 3 of item 2.1, with the instruction to
   **re-derive** the count from `pytest --collect-only -q` rather than
   increment the number on the page, and to extend the same bullet's
   empty-body coverage sentence to name the `edit`-to-empty route.
   **Status**: FIXED

6. **`D3`'s fate in the rewritten docstrings was unstated** — the two
   docstrings item 1.1 re-authors cite `(FR5/FR6/FR7/D3)`, and `D3` resolves
   nowhere in the repo. The runbook's own rule is "no new dangling citation is
   added", but re-typing one into a line being re-authored is ambiguous
   between that rule and m12's out-of-scope marker; two executors would
   diverge. Fix: stated — the new docstrings cite `FR5/FR6/FR7`, `D3` is not
   re-typed, and m12's one remaining live case (`D2` at
   `tests/test_checkpoint.py:603`) stays out of scope. Verified by grep that
   those three are the only live `D<n>` citations.
   **Status**: FIXED

7. **The changelog index line's shape was underspecified** — the item said
   "takes the entry's index line, newest first", which admits a bare link.
   Both neighbouring rows carry a substantial summary hook after the em dash.
   Fix: the shape and the hook's content are now stated.
   **Status**: FIXED

8. **The changelog filename pinned a date the prose says is not fixed** — the
   item's target path hardcodes `2026-09-10` while its body says "dated the
   day it lands". Fix: the filename is now stated as an assumption, with the
   rule for a later landing date.
   **Status**: FIXED

9. **`FilePlan` described as "Frozen" while carrying a `list[str]`** — a
   `NamedTuple` with a list field is not frozen in the sense the word invites.
   Fix: scoped to "the record itself is frozen", with the reason
   `manifest_lines` stays a plain list (`write_manifest`'s signature does not
   move). The type is unchanged — this is a wording fix, not a design
   decision.
   **Status**: FIXED

10. **FR4's guarantee named no regression guard** — `keep` must not fall
    through to the resolver, whose rule would read its empty content as a
    removal. Fix: named `test_todo_keep_leaves_pre_existing_list_alone` as the
    row that reds if it does, so FR4 traces to an executable claim rather than
    to prose.
    **Status**: FIXED

11. **"None of the four names is cited outside `tests/test_checkpoint.py`" was
    literally false** — `plans/` cites all four. Harmless, since those are
    frozen, but a corpus claim carried forward without its exception. Fix:
    scoped to live citations, with the `plans/` hits named as frozen and the
    grep scope widened to what was actually checked.
    **Status**: FIXED

## Checks that passed without a fix

- **Red evidence is genuine.** The three negatives fail today on the
  surviving-task-file assertion, not on a missing symbol: `main` applies
  `apply_task` (`:546`) before `apply_todo` (`:547`), and the todo half's
  three `err()` sites exit 2 before `write_manifest`. The assertion order the
  item specifies puts the task-file claim ahead of the no-manifest claim, so
  the first failure is the intended one — the no-manifest assertion is green
  before and after, as the item says.
- **The two green-today rows are correctly identified as characterisation.**
  Traced by hand against unchanged `apply_task`/`apply_todo`: the positive
  yields exactly `D task` + `W todo`; the `edit`-to-empty row yields exit 0,
  no todo file, `D todo` in the manifest.
- **Mutation (a) is sound** — restoring today's ordering reds the three
  negatives and nothing else; nothing in `plan_todo` reads the task file.
- **Mutation (b)'s "will not red alone" is honest** — `clear` resolving to the
  empty string means the `clear` rows read the same resolver, and the runbook
  says so rather than claiming an isolated red.
- **`keep`, `clear`, `write` and `edit` all preserve observable behaviour**
  under the restructure, checked arm by arm against `checkpoint.py:392-450`,
  including the never-existed `[]` returns.
- **The double stat on the `edit` route is deliberate and stated.**
- **Dependencies**: no cycle. Item 2.1 declares `Depends on: Item 1.1` and
  instructs reading `checkpoint.py` as 1.1 left it before writing the entry —
  post-phase state awareness is present.
- **Format**: no code blocks in any item; `Interfaces:` is one contract per
  line with full signatures and return types; `Requirements:` on both items;
  literal strings that cross the boundary (`Literal["write", "remove",
  "none"]`, the `W`/`D` manifest lines, the test names) are verbatim; no
  "choose"/"decide"/"determine" language anywhere (grepped).
- **Growth projection**: `scripts/checkpoint.py` 559 lines today; the
  restructure trades three functions for five and lands roughly +30. No phase
  split is warranted — this repo sets no line cap, the file is already past
  any generic figure, and splitting it is explicitly out of scope.
  `tests/test_checkpoint.py` 2041 lines, +1 row ≈ +25.
- **Phase structure**: two phases, one item each; foundation (code+tests) then
  the docs that depend on it. No phase over 8 items, no disproportion.
- **Vacuity**: neither item is scaffolding-only. Item 2.1 is required by this
  repo's own same-pass documentation convention, not optional follow-up.
- **Out-of-scope fencing**: the validators, the manifest format,
  `bash-post.sh`, the sentinel composer, `_checkpoint_lib.py`, both `SKILL.md`
  bodies and everything frozen under `plans/` are named. The one frozen
  citation that would otherwise look like a missed rename
  (`docs/changelog/2026-09-07-…:53`) is called out with its reason.

## Fixes Applied

- Header — the guarantee scoped to the two halves and their manifest;
  `compose_sentinel`'s read-back `err()` named beside `OSError` as outside it,
  with the reason it is not a counterexample.
- After the requirements table — a sentence naming FR1, FR3, FR8, FR9, FR-G,
  FR-H, NFR2, NFR3 as out of the change's reach.
- "Corrected against the outline" — grew to two numbered corrections; the
  second records the `CLAUDE.md`-is-not-one-bullet finding against the
  outline's claim, and the first now states what happens to `D3` and `D2`.
- Item 1.1, test-name grep claim — scoped to live citations, `plans/` named as
  frozen, grep scope widened to what was checked.
- Item 1.1, `keep` — `test_todo_keep_leaves_pre_existing_list_alone` named as
  the regression guard.
- Item 1.1, rename enumeration — three definitions and three call sites with
  line numbers; `D3` not re-typed into the rewritten docstrings, `D2` left to
  m12.
- Item 1.1, mutation checks — (c) replaced with a mutation that discriminates
  the positive row; (d) added for existence sampling, naming the four
  never-existed rows and stating that the positive must stay green under it.
- Item 1.1, `Interfaces:` — `FilePlan`'s "Frozen" scoped to the record, with
  the reason `manifest_lines` stays a list.
- Item 2.1 — changelog filename date rule; index-line shape and hook;
  `docs/design.md` sentence bound to the header's scope; `CLAUDE.md` expanded
  from one site to three (`:543`, `:614`, `:802`); "All four edits" → "All
  four files".
- Line rewrapping where a fix left an over-long line.

## Design Alignment

No decision in the proofed outline is contradicted. Checked one by one:

- Decision 1 (plan-then-apply, not a hoisted precondition) — item 1.1 states
  it structurally; the rejected remedy's two reasons survive into the
  changelog entry item 2.1 specifies.
- Decision 2 (remedy (c) rejected) — carried into the changelog entry.
- Decision 3 (`apply_edit` → `edited_body`, no alias, every citation moves in
  the same pass) — enumeration completed, not narrowed.
- Decision 4 (m3 falls out; the `edit`-to-empty row is added because it has no
  coverage) — unchanged; the new row and mutation (b) are its evidence.
- Decision 5 (`keep` takes no stat) — unchanged; the runbook's existing
  correction of the outline's dangling `(D5)` to FR4 stands and is verified —
  no `D5` exists anywhere in the repo, and `docs/design.md` numbers no
  decisions at all.

Two departures from the outline are additive rather than contradictory, and
both are recorded in the runbook: the `CLAUDE.md` site count (the outline's
"nothing else in it moves" is true of the bullet it was written about and
false of the file), and mutation (c), which the outline does not specify at
all — it lists only the ordering and empty-body mutations, both of which the
runbook keeps intact.
