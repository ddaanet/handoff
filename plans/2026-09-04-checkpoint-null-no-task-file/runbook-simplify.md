# Runbook simplification pass — the checkpoint payload names its actions

Target: `plans/2026-09-04-checkpoint-null-no-task-file/runbook.md`.
Read against `outline.md`, `runbook-review.md`, `CLAUDE.md`, and
`scripts/checkpoint.py` (the actual `validate_*`/`apply_*` bodies the slices
decompose).

**Outcome: one consolidation applied.** Item 1.1's slices 3 and 4 merged into
one; slice 5 renumbered to 4. Item count and phase count unchanged. Diff is
20 insertions / 18 deletions in `runbook.md` alone; working tree left dirty,
nothing committed.

## Applied — Item 1.1 slices 3 + 4 → one slice

Old slice 3 was "an unrecognized or malformed action is a named error"
(parametrized: unknown action, `keep` on `task`, `edit` on `task`, no `action`
key, a non-string non-object). Old slice 4 was "the edit action's own required
keys" (`{"action": "edit"}` with only `old_string`, then only `new_string`).

They are one slice on the merits:

- **Same assertion shape, no discrimination between them.** Every case in both
  is `payload → exit 2, stderr names the offending field`. Nothing in slice 4
  asserts anything slice 3 does not.
- **Same code.** `validate_todo`'s dispatch on `action` is where both land.
  Slice 4's whole GREEN increment is the one line the current
  `validate_todo` already carries —
  `if not (has_old and has_new): err("todo", …)` (`scripts/checkpoint.py:333-334`)
  — carried into the new `edit` branch. A slice whose GREEN is one `if` line
  over tests written in the previous slice does not earn a RED/GREEN dispatch
  pair.
- **Same content boundary.** An `{"action": "edit"}` object missing a required
  key *is* a malformed action; the old slice 3 already contained
  `{"action": "edit", …}` as one of its cases (on `task`).

Every case, test name and line citation from both slices is carried into the
merged text verbatim, including the three unchanged-assertion rows
(`test_todo_edit_old_string_absent_errors` etc., 757/780/802) and the
"restated as the positive contract of the union" framing for 428/468/487. The
merged slice opens with a one-clause note on why it is not two, so a later
reader does not re-split it.

Renumbering fallout, all fixed: `slice 5` → `slice 4` at the Phase 0 safety
argument (line 100) and in Item 2.1's dependency sentence (line 297).
`Slice 2 below…` at line 165 is unaffected.

## Rejected — slice 2 stays separate

The obvious extension is to fold slice 2 (`null` and an absent key are each a
named error) into the merged rejection table, since its assertion shape is
identical. Rejected, on two grounds:

- **It has its own implementation increment, in a different function.**
  Slice 2's GREEN is the required-by-key-presence check *plus* the
  `if skill in ("handoff", "precompact")` gate in `main` — the C1 critical
  finding. That is the only slice touching `main`, and it is the change that
  keeps D2 from breaking `autoname` and `restart`.
- **It carries its own pairing.** The negative (key absent ⟹ exit 2) is
  guarded against over-reach by two *existing* positives —
  `test_autoname_manifest_present_empty_neither_file_touched` (1408) and
  `test_restart_manifest_present_empty_neither_file_touched` (1484), which red
  against an ungated `validate_task`. Merging would bury a critical-finding
  regression guard inside a twelve-case table.

## Rejected — slices 1 and 5(now 4) stay separate

Both are pre-existing/never-existed pairs over the removal semantics (D3), and
both exercise `apply_task`/`apply_todo`. Tempting to merge as "the whole
`apply_*` contract". Rejected: they are genuinely different branches. Verified
against `scripts/checkpoint.py:358-380` — today `apply_task` writes first and
*then* unlinks on an empty body, so the phantom `D` lives in the **write**
path. An implementation that satisfies slice 1 (sample existence, `clear`
writes nothing) can leave the write path's phantom `D` fully intact. Slice
5's never-existed halves therefore force real new code, and they are the
guarantee Phase 0's meaning-preservation argument and Phase 2's `ls-files`
guard both lean on.

## Rejected — item-level merges

- **Phase 0 into Phase 1.** Out of bounds by instruction, and correct: Phase 0
  is what makes Phase 1's red a failed assertion rather than ~118 unrelated
  payload rejections.
- **Item 3.1 into Item 4.1** (both `inline`, both prose). Rejected: different
  artifacts with different constraints — `SKILL.md` is agent-facing operative
  prose against a hard 2000-word budget with 29 words of headroom, the design
  record is write-time narrative with a supersession convention. Merging also
  flattens a real dependency edge: 3.1 depends on 1.1 only, 4.1 on 1.1 + 2.1
  + 3.1, so 3.1 can run while 2.1 is still open.
- **Items 1.1 and 2.1.** Different files, and the tdd/inline phase-type
  boundary is not to be crossed.
- **Items 0.1, 2.1, 3.1, 4.1 among themselves.** Each is already the maximal
  single-file (or single-artifact-set) unit; 3.1 and 4.1 are themselves
  already consolidations of two and four files respectively.

## Constraints checked

- Requirements mapping table: untouched, byte-for-byte. Every requirement ID
  still traces to an item — no item was added, removed or renumbered.
- Phase 0 / Phase 1 separation: intact.
- Pairing discipline: no pair collapsed. Slice 1's `clear` pair, slice 4's two
  empty-body pairs, slice 2's negative-plus-existing-positives, and Item 2.1's
  staged-then-deleted / never-in-the-index bats pair all survive.
- Item 1.1's `main` boundary-skill gate paragraph: untouched.
- Item 2.1's `ls-files` guard: untouched.
