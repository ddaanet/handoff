# Item 1.1 slice 3 — test review

Verdict: **accepted with fixes applied.** The report's ten-mutation matrix
reproduces **cell for cell**, independently, on my own runs — no disagreement
on any cell, and every one of the ten rows reds under at least one single
mutation. No critical finding: there is no case the matrix cannot red.

Three findings, all fixed and all re-mutated afterwards to confirm the fix
made a previously-unfalsifiable row falsifiable without breaking the
disjointness of the original matrix:

- **Major** — `todo_edit_missing_old_string` passed under a *weakened*
  `old_string` guard, not just a deleted one. Its `reason` was the bare
  substring `old_string`, which the downstream `todo.old_string: edit
  requested but … does not exist` error also carries.
- **Minor** — `task_no_action_key` / `todo_no_action_key` could not tell
  `<field>.action: required` from the absent-key `<field>: required, …`.
  Conflating the two diagnostics left the **whole file green**.
- **Minor** — the docstring's ordered correspondence between the three
  restating ids and the three deleted tests was swapped for the last two.

Test count is unchanged at **122**; no row was added or removed, only three
`reason` strings tightened and one docstring sentence corrected.

`git diff --stat scripts/checkpoint.py` was empty when this review began and
is empty now. No mutation was left in.

## Mechanical first check — the mutation matrix, reproduced

Per the runbook's write-then-mutate adaptation, this stands in for the RED
output. Method, and the slice 2 restore hazard specifically guarded against:

- A scripted patcher (`$TMPDIR/mutate.py`) with `assert s.count(old) == 1`
  before every replacement, so a mutation that fails to apply is an error, not
  a silent green.
- Every cycle is `git checkout -- scripts/checkpoint.py` **first** (clean
  baseline, never a `cp` from a saved copy), then mutate, then run, then
  `git checkout --` again, then `git diff --stat scripts/checkpoint.py`
  asserted empty **in the shell** — the runner aborts on a non-empty diff. It
  printed `restore-ok` on all 26 cycles.
- One mutation per cycle. Never stacked.
- Tests never relocated.

### The report's ten, reproduced

| # | Mutation (as I reconstructed it) | Rows reddened — report | Rows reddened — mine |
|---|---|---|---|
| M1 | `validate_task`: `action in ("clear", "keep")` | `task_keep_rejected` | **same** |
| M2 | `validate_task`: `action in ("clear", "edit")` | `task_edit_rejected` | **same** |
| M3 | `validate_task`: final `err` → `return "clear", ""` | `task_unknown_action`, `task_keep_rejected`, `task_edit_rejected` | **same** |
| M4 | `validate_todo`: final `err` → `return "keep", "", "", ""` | `todo_unknown_action` | **same** |
| M5 | `validate_task`: `action is None` branch neutered | `task_no_action_key` | **same** |
| M6 | `validate_todo`: `action is None` branch neutered | `todo_no_action_key` | **same** |
| M7 | `validate_task`: `ttype in ("string", "number")`, `str(task)` | `task_not_string_or_object` | **same** |
| M8 | `validate_todo`: same for todo | `todo_not_string_or_object` | **same** |
| M9 | `validate_todo`: `old_string` presence guard deleted | `todo_edit_missing_old_string` | **same** |
| M10 | `validate_todo`: `new_string` presence guard deleted | `todo_edit_missing_new_string` | **same** |

Nine disjoint, M3 the deliberate group of three. Agrees with the report
exactly. Every mutation description in the report was reconstructable
unambiguously from its one-line rule — none required guessing.

## Lead 2 (no finding) — M3's group-red does not paper over a row

The report justifies M3 by saying M1/M2 show `task_keep_rejected` and
`task_edit_rejected` are *also* individually reachable. That leaves
`task_unknown_action` reachable only through M3 in the submitted matrix, which
is exactly the shape a papered-over row would have.

I added a mutation the report did not have:

- **M12** — `validate_task`'s allow-list inverted into a deny-list:
  `if action is None: err(...)`, then `if action not in ("keep", "edit"):
  return "clear", ""`, keeping the `err` only for the two todo-only actions.

M12 reds **`task_unknown_action` alone** (1 failed, 9 passed). So all three
task rows are individually reachable by a mutation that leaves the other two
green, and M3's group-red is benign — it removes the single line all three
happen to share, which is a property of the implementation, not a gap in the
table. The report's justification holds; M12 is the evidence it was missing.

## Finding 1 (major, fixed) — the `edit`-key rows were pinned only against deletion

The dispatch flagged that M9/M10 red on an uncaught `KeyError` (exit 1 +
traceback) rather than on the validator's named-error path, and asked whether a
mutation that *keeps* the graceful path would still red them. It would not, on
one of the two:

- **M9w** — the guard weakened rather than deleted:
  `todo.setdefault("old_string", "")` in place of the `err`. The payload then
  validates as `edit("", "b")`, reaches `apply_todo`, and errors at
  `todo.old_string: edit requested but .claude/handoff-todo.md does not exist`
  — **exit 2**, stderr containing `todo` and `old_string`.

  Result: **10 passed, 112 deselected.** The row is green while the
  `edit`-requires-`old_string` rule is gone.

- **M10w** — the same weakening for `new_string`. This one *did* red, but only
  by accident of namespacing: the downstream file-missing error is filed under
  `todo.old_string`, so the `new_string` reason substring is absent. The
  asymmetry is the tell — neither row was pinning the diagnostic it claimed to.

The dispatch's diagnosis was right and understated: with the reason substring
being the bare `old_string`, the exit-code axis was doing all the work, and
the exit-code axis is exactly what a graceful weakening restores. The
`todo.old_string` namespace carries four distinct messages (`required for`,
`not found in`, `ambiguous`, `does not exist`), three of them already asserted
by `test_todo_edit_old_string_absent_errors` /
`test_todo_edit_old_string_ambiguous_errors` /
`test_todo_edit_requested_file_missing_errors`, so the bare field name
discriminates none of them.

**Fix** — both `edit`-key rows now pin their own message:

```python
(
    "todo",
    {"action": "edit", "new_string": "b"},
    'old_string: required for {"action": "edit"}',
),
(
    "todo",
    {"action": "edit", "old_string": "a"},
    'new_string: required for {"action": "edit"}',
),
```

Re-mutated after the fix: **M9w now reds `todo_edit_missing_old_string` alone**
(1 failed, 9 passed), and M9/M10 still red their own row alone — now on two
axes (exit code *and* reason) rather than one. M10w still reds its own row
alone. The four remain mutually disjoint.

## Finding 2 (minor, fixed) — the no-`action`-key rows conflated two diagnostics

`task_no_action_key` asserted `task` + `required`. The real message is
`task.action: required`; the absent-key message slice 2 owns is
`task: required, a content string or {"action": "clear"}`. Both contain both
substrings, so the two spellings — *the field is missing* and *the object is
missing its action* — are indistinguishable to this table.

- **M11b** — `err("task.action", "required")` replaced by
  `err("task", 'required, a content string or {"action": "clear"}')`, i.e. the
  `{}` case reports the absent-key diagnostic.
- **M6b** — the todo twin.

Against the whole file, both are **122 passed**. Slice 2's rows do not catch
it either (their absent-key path is untouched), so the repository is entirely
green while the two errors have been merged.

This is the same class as slice 2's own minor finding 2, and the same remedy:
pin each shape's own reason. **Fix** — reason becomes `"action: required"` for
both rows. That substring is present in `task.action: required` /
`todo.action: required` and absent from both absent-key messages (neither has
a colon after `action`). Re-mutated: **M11b reds `task_no_action_key` alone,
M6b reds `todo_no_action_key` alone.** M5/M6 still red their own row.

Also probed, and no finding: **M5w** — the `action is None` branch weakened to
`return "clear", ""` rather than deleted. `task_no_action_key` reds under it
both before and after the fix, so that row was never pinned only against
outright deletion.

## Finding 3 (minor, fixed) — the docstring's restatement pairing was swapped

The docstring reads:

> `task_edit_rejected`, `todo_edit_missing_old_string` and
> `todo_edit_missing_new_string` restate […] `test_task_with_old_string_new_string_errors` /
> `test_todo_only_old_string_errors` / `test_todo_only_new_string_errors`

The ordering implies a 1:1 map, and it is inverted for the last two. The
deleted `test_todo_only_old_string_errors` sent a payload carrying **only**
`old_string` — i.e. missing `new_string` — so it restates as
`todo_edit_missing_new_string`, not `..._old_string`.

Nothing was dropped; both contracts are covered, and the ids are accurate to
themselves (they name the *missing* key, where the deleted tests named the
*present* one). Only the stated correspondence was wrong. Fixed by reordering
the second list, and the docstring now also records why each `reason` is
message-specific rather than field-specific (finding 1's rationale, which is
not legible from the parametrize table alone).

## Lead 3 — the three deleted rows, restatement verified

| deleted | restated as | contract |
|---|---|---|
| `test_task_with_old_string_new_string_errors` | `task_edit_rejected` | `task` cannot carry an `edit` |
| `test_todo_only_old_string_errors` | `todo_edit_missing_new_string` | `edit` requires `new_string` |
| `test_todo_only_new_string_errors` | `todo_edit_missing_old_string` | `edit` requires `old_string` |

Each deleted test asserted exactly `returncode == 2` and `<field> in stderr`.
Each restating row asserts both of those **plus** a reason. Nothing was
dropped; the assertions strictly strengthened. The deleted forms
(`{"file_path": …, "old_string": …}` on a bare object) no longer exist under
the union, so deleting rather than inverting them is right per
`remove-cleanly-no-vestigial` — an inverted test of `file_path` key sniffing
would be an absence-guard defending a form the schema can no longer express.

## Lead 4 — the three untouched rows, verified not accepted

`git diff tests/test_checkpoint.py` carries exactly **one contiguous changed region**, at
`tests/test_checkpoint.py:429-505`. `test_todo_edit_old_string_absent_errors`,
`test_todo_edit_old_string_ambiguous_errors` and
`test_todo_edit_requested_file_missing_errors` (now `:718`, `:737`, `:755`)
are outside it and unedited, and each already builds its payload through
`todo_edit(…)`. The report's claim is accurate.

One observation, **not a finding and out of this slice's scope**:
`test_todo_edit_requested_file_missing_errors` asserts only
`"does not exist" in result.stderr` — no field name at all. That is
pre-existing and the runbook's own instruction is that these three "keep their
assertions unchanged". Recording it because finding 1 above is what makes the
`todo.old_string` namespace's four messages worth telling apart.

## Lead 5 (no finding) — the absent `skill` dimension costs nothing

Verified rather than accepted. Reproduced slice 2's mutation D:

- **MD** — `main`'s gate narrowed from `if skill in ("handoff", "precompact"):`
  to `if skill in ("handoff",):`.

Against the whole file: **4 failed, 118 passed**, the four failures being
exactly `test_task_or_todo_null_or_absent_errors_naming_field[*-precompact]`.
Slice 2's table does still pin the gate. Slice 3's table is green under MD, as
expected from its uniform `"skill": "handoff"` — but the gate it would be
duplicating is already load-bearing elsewhere, and slice 3's rows reach
`validate_task`/`validate_todo` through that same one gate with no
skill-dependent branch below it (confirmed by reading both validators: neither
takes `skill` as a parameter nor reads it from the payload). Doubling the
table to 20 rows would add no discrimination. **The instruction not to widen
was correct.**

## Reviewed as tests

- **Own-field naming** — yes. Only one field is malformed per row; the other
  carries a well-formed `task_clear()` / `todo_keep()`. Each validator names
  its own field, and neither field's message contains the other's name, so an
  exchanged predicate reds.
- **Reason specificity** — now yes on all ten, after findings 1 and 2. Before,
  four of the ten (`task_no_action_key`, `todo_no_action_key`,
  `todo_edit_missing_old_string`, `todo_edit_missing_new_string`) asserted a
  substring their own shape does not uniquely own.
- **Mutually distinct** — yes: nine disjoint single-row mutations plus M3's
  deliberate group, and M12 shows M3's group members are individually
  reachable. Sixteen mutations run in total; no mutation reddens every row,
  and no row is unreachable.
- **Coverage against the runbook's enumeration** — complete. All seven
  enumerated cases present, the four two-sided ones parametrized over both
  fields: unknown action ×2, `keep` on task, `edit` on task, no `action` key
  ×2, non-string-non-object ×2, `edit` missing each key.
- **Positives pairing the negatives** (`green-is-not-evidence`) — present, from
  slice 1, over the same fixture shape: `test_task_write_creates_file_…_w`,
  `test_todo_write_creates_file_…_w`, `test_todo_edit_replaces_…_w`,
  `test_todo_keep_leaves_pre_existing_list_alone`, and the two `clear` rows.
  The union's accepted vocabulary is positively pinned; no new positive needed
  here.
- **File idiom** — `("field", "value", "reason")` matches the three-column form
  slice 2 established at `:515` and the `("field", "value")` sites at `:1377`
  and `:1489`. Explicit `ids=` keeps case names readable. Placement
  immediately before `test_malformed_json_errors_naming_payload`, in the
  "Schema validation (FR2)" section, is where the three deleted tests were.
- **Payload hygiene** — `payload[field] = value` overwrites a well-formed
  baseline, so the row's own value is the only defect.
- **Docstring length** — the second-longest in the file. Kept, and slightly
  extended by finding 3's fix, for the same reason slice 2's review kept its
  own: the reason column's message-specificity is not legible from the table.
  `docformatter --check` accepts it.

## What I did not touch, per scope

`scripts/checkpoint.py` (transiently mutated 26 times, restored and asserted
clean every time, unmodified now); slice 4's empty-body/`D` pairs;
`bash-post.sh`; both `SKILL.md` bodies; `docs/`; `CLAUDE.md`. The open residual
recorded on the item — no test asserts that `precompact` *applies* task/todo
content — was left alone as instructed; MD's result above is consistent with
it (the four `precompact` rows that red are validation-side only).

## Verification

- `pytest tests/test_checkpoint.py -q` — **122 passed**.
- `just precommit` — **green**: manifest + settings lint, `shellcheck -x`,
  `ruff check` / `ruff format --check` / `docformatter --check` / `mypy` /
  `ty check` all clean, `bats tests/hook-test.bats tests/checkpoint.bats` →
  **159 ok**, `pytest` (whole suite) → **212 passed, 11 deselected**.
- `git diff --stat scripts/checkpoint.py` — **empty**.
- `git status --short` — `tests/test_checkpoint.py` modified; the two reports
  untracked; `.claude/handoff-task.md` and `.claude/handoff-todo.md` staged
  before this dispatch and unrelated to it.

No commit made.
