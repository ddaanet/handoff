# Simplification Report

**Runbook:** `plans/2026-09-08-apply-before-mutate/runbook.md`
**Design:** `plans/2026-09-08-apply-before-mutate/outline.md` (proofed item by
item 2026-09-10 — its decisions treated as settled)
**Prior pass:** `plans/2026-09-08-apply-before-mutate/reports/runbook-review.md`
**Date:** 2026-09-10

## Summary

- Items before: 2
- Items after: 2
- Consolidated: 0 items across 0 patterns

**No consolidation candidates.** The runbook was not modified. This is not a
skipped gate — the three consolidation categories were checked against it one
by one, and the one candidate with any surface (the five test rows in item
1.1's slice) was read against the existing rows in
`tests/test_checkpoint.py:890-968` and against the file's own style for that
shape, then rejected on the evidence below rather than on the item count.

## Consolidations Applied

None.

## Patterns Examined

### 1. Identical-pattern items — not present

Two items, and they are not instances of one pattern: item 1.1 restructures
`scripts/checkpoint.py`'s apply phase with its tests (type `tdd`), item 2.1
writes the docs that restructure falsifies (type `general`). Different files,
different phases, and 2.1 declares `Depends on: Item 1.1`. Nothing to merge.

### 2. Independent same-module functions — already consolidated upstream

Item 1.1 introduces five interfaces in one module (`FilePlan`, `plan_task`,
`plan_todo`, `edited_body`, `apply_plan`, `_plan_file`) and they are already
one item, not five. Item 2.1 carries four files
(`docs/changelog/<date>-…md`, `docs/changelog.md`, `docs/design.md`,
`CLAUDE.md`) in a single pass and a single commit, and its closing paragraph
states the bundling rule that puts them there. Splitting either would be the
inverse of this pass; there is nothing left to batch.

### 3. Sequential additions — not present

No item adds one element to a structure another item also adds to. The three
`CLAUDE.md` sites inside item 2.1 (`:543`, `:614`, `:802`) are three edits in
one item, which is already the consolidated form; the review pass that just
ran created that shape (its Major 2 and Minor 5), and re-splitting them is not
available to this pass.

### 4. The five test rows → one `pytest.mark.parametrize` — examined and rejected

This is the only candidate with real surface, and it was checked against the
code rather than judged from the runbook's prose. Four of the five rows exist
today at `tests/test_checkpoint.py:890` (`..._replaces_first_occurrence_stages_w`),
`:915` (`..._old_string_absent_errors`), `:934` (`..._old_string_ambiguous_errors`)
and `:952` (`..._requested_file_missing_errors`). Rejected for four reasons,
in descending weight:

1. **The collapsible subset is three rows, and the two green-today rows cannot
   join them.** The positive asserts exit 0, the task file gone, the todo
   file's replacement, and a manifest of *exactly* two lines; the new
   `edit`-to-empty row asserts exit 0, the todo file gone, and `D` for the
   todo. Neither shares the negatives' post-state shape. So the maximum
   collapse is 3 → 1 inside a single slice of a single item — it changes no
   item count, no phase, no dispatch, and no `Requirements:` line.

2. **The three negatives do not share a fixture, which is the premise the
   consolidation rests on.** The runbook's "one fixture" is the *task* half —
   a pre-existing `.claude/handoff-task.md` plus `{"action": "clear"}` —
   identical throughout. The todo halves are three different on-disk states:
   one item (`## Remaining\n\n- keep this\n`), the same item twice
   (`- dup\n- dup\n`), and no todo file at all. Their post-conditions differ
   with them: rows 1 and 2 assert the todo file's bytes unchanged; row 3 has
   no file for that assertion to be about. A table would have to carry a
   `str | None` pre-state column whose `None` means "and skip the
   unchanged-bytes claim" — a row that encodes the absence of an assertion,
   which is worse to read than three named functions.

3. **The file's own style for a `(fixture, stderr fragment)` table is a
   different shape.** The nearest analogue is
   `test_task_or_todo_action_vocabulary_errors_naming_field`
   (`tests/test_checkpoint.py:435-560`), a 20-row `(field, value, reason)`
   table with explicit `ids`. Every row there runs against a bare
   `make_repo(tmp_path)` with no on-disk state and asserts nothing about the
   filesystem afterwards — it is *schema* validation, where the payload is the
   only variable. The apply-phase rows here vary the disk and assert the disk.
   The file does parametrize with conditional bodies elsewhere (`:620`,
   `:662`, `:831`, `:1934`, `:1955`), but each branches on `skill` where the
   branch *is* the claim under test; here the branch would exist only to
   paper over a fixture mismatch. The file's style points away from the
   collapse, not toward it.

4. **The three negatives are the red, and the runbook's evidence protocol
   names them individually.** The protocol requires recording that each fails
   on its surviving-task-file assertion — "not on a missing symbol, and not on
   the no-manifest assertion" — and mutation (a) requires confirming "the
   three negatives red again and nothing else does". Parametrized ids could
   carry that, so this is not decisive on its own; it is listed because it
   removes the last reason to spend the churn.

A fifth consideration, recorded because it bounds this pass rather than
because it decides it: the outline is proofed and enumerates five rows, and
the four existing ones are to be **extended in place**, which the runbook says
explicitly. Rewriting them into a table is a different change to
`tests/test_checkpoint.py` than the settled design prescribes, so it is not a
consolidation this pass may apply unilaterally even if the four reasons above
had gone the other way.

## Requirements Mapping

**No changes — all mappings preserved.** The runbook was not edited, so the
table at `runbook.md:28-35` is untouched. Verified that it still traces every
row in item 1.1's slice, which is what the collapse would have disturbed:

| Row | Requirement | Traced via |
|---|---|---|
| `..._old_string_absent_errors_task_file_survives` | FR2, FR7 | FR2 row (the three `err()` sites keep their field names); FR7 row (a wrap-up that fails writes no manifest) |
| `..._old_string_ambiguous_errors_task_file_survives` | FR2, FR7 | same two rows |
| `..._requested_file_missing_errors_task_file_survives` | FR2, FR7 | same two rows |
| `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` | FR5, FR7 | FR5 row (write semantics observably unchanged); FR7's exact-two-lines claim |
| `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` | FR6 | FR6 row (the emptiness test moves to the resolved body) |
| `test_todo_keep_leaves_pre_existing_list_alone` (existing guard) | FR4 | FR4 row (`keep` short-circuits, takes no stat) |

NFR1 traces to item 1.1 as a whole (no new subprocess, no new import), and
FR5/FR6/FR7 additionally trace to item 2.1's doc rewrites. The sentence at
`runbook.md:37-41` naming FR1, FR3, FR8, FR9, FR-G, FR-H, NFR2 and NFR3 as out
of reach is still accurate.

## Structural Validation

- Phase structure intact: two phases (`## Phase 1 … (type: tdd)` at `:73`,
  `## Phase 2 … (type: general)` at `:238`), one item each, no orphans.
- Item numbering sequential within phases: 1.1, then 2.1.
- No forward dependencies: item 2.1's `Depends on: Item 1.1` points backward.
- Assertion count per item unchanged; no item was split or merged.
