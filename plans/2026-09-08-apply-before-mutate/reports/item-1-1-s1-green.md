# Item 1.1, slice 1 — GREEN

Commit: `86d7024` — "🐛 Item 1.1/1 — whole or nothing, and the edit-to-empty
route stays intact" (subject typed `fix:`, rewritten by the commit-msg hook).
Carries `scripts/checkpoint.py`, `tests/test_checkpoint.py`, and the two
already-written report files (`item-1-1-s1-red.md`, `item-1-1-s1-test-review.md`).

## What changed

`scripts/checkpoint.py`: `apply_edit`/`apply_task`/`apply_todo` retired, no
alias. Replaced by:

- `FilePlan(NamedTuple)` — `act: Literal["write", "remove", "none"]`, `path`,
  `body`, `manifest_lines`.
- `edited_body(field, path, old, new) -> str` — `apply_edit`'s rename; returns
  the replacement instead of writing it.
- `_plan_file(path, rel, body) -> FilePlan` — the shared resolver: samples
  existence, applies FR6's emptiness rule, produces exactly one of the three
  shapes.
- `plan_task(root, action, content) -> FilePlan` — `clear` resolves to `""`,
  reaching removal through `_plan_file`'s own rule.
- `plan_todo(root, action, content, old, new) -> FilePlan` — `keep`
  short-circuits to the empty plan ahead of `_plan_file` (no stat); `edit`
  keeps its own file-absent `err()` ahead of `edited_body`, then hands the
  edited body to `_plan_file`, which takes its own (deliberate) second stat.
- `apply_plan(plan) -> None` — performs the write or the unlink; no failure
  branch.

`main()` now builds both plans, applies both, then concatenates
`task_plan.manifest_lines + todo_plan.manifest_lines` into `write_manifest`.

Renamed citations: `_todo_edit_strings`'s docstring (`apply_edit` →
`edited_body`) and `tests/test_checkpoint.py`'s docstring at the
`test_task_or_todo_action_vocabulary_errors_naming_field` test (same rename,
the one permitted test-file edit). `docs/design.md:240` and
`docs/changelog/2026-09-07-…:53` left untouched per the dispatch's scope-out
(item 2.1's / frozen write-time record).

Two docstrings (`FilePlan`, `edited_body`, `_plan_file`) needed
`docformatter --in-place` before `just precommit` would pass — same lint gap
the RED phase hit, now caught before commit.

## Order the tests were made to pass

All five slice rows and every pre-existing row in `tests/test_checkpoint.py`
were already in the tree (RED + test-review passes, uncommitted). The GREEN
dispatch made the whole suite pass in one shot with the plan/apply
restructure above — there was no incremental per-test order within this
slice; `pytest tests/test_checkpoint.py -q` went from `3 failed, 136 passed`
to `139 passed` in the single edit pass described above. Verified before
committing:

```
$ pytest tests/test_checkpoint.py -q
........................................................................ [ 51%]
...................................................................      [100%]
139 passed in 21.62s
```

## `just precommit`

All green, no warnings: jq manifests, `shellcheck -x`, `ruff check`,
`ruff format --check`, `docformatter --check` (after the in-place pass noted
above), `mypy`, `ty check`, `bats tests/hook-test.bats tests/checkpoint.bats`
(164 ok), `pytest` (229 passed, 11 deselected — the `live` marker).

## Mutation checks

All four run after the commit, each mutated via a single Python
`str.replace` on the exact string (count-asserted to 1 first), restored by
inverting the same replacement in the same call, and proven restored via
`git diff --stat scripts/checkpoint.py` (empty) plus a green
`pytest tests/test_checkpoint.py -q` before the next mutation.

### (a) Ordering

Mutation — swapped the two `main()` lines so `apply_plan(task_plan)` runs
immediately after `plan_task`, before `plan_todo` is even called:

```python
# before
task_plan = plan_task(root, task_action, task_content)
todo_plan = plan_todo(root, todo_action, todo_content, todo_old, todo_new)
apply_plan(task_plan)
apply_plan(todo_plan)

# after (mutated)
task_plan = plan_task(root, task_action, task_content)
apply_plan(task_plan)
todo_plan = plan_todo(root, todo_action, todo_content, todo_old, todo_new)
apply_plan(todo_plan)
```

Reds: exactly the three intended negatives —
`test_todo_edit_old_string_absent_errors_task_file_survives`,
`test_todo_edit_old_string_ambiguous_errors_task_file_survives`,
`test_todo_edit_requested_file_missing_errors_task_file_survives` — each on
`assert task_path.is_file()`. `3 failed, 136 passed`, nothing else moved.
Predicted row: confirmed, and it was all three, not just one.

Restore: inverted the swap back. `git diff --stat scripts/checkpoint.py`
empty; `pytest tests/test_checkpoint.py -q` → `139 passed`.

### (b) Empty-body route

Mutation — in `_plan_file`, replaced `if lib.is_empty_body(body):` with
`if False:  # MUTATION(b): emptiness test dropped from the shared resolver`,
forcing every route through `"write"`.

Reds (12): the target row
`test_todo_edit_emptying_the_list_removes_it_manifest_records_d` plus
`test_task_clear_removes_pre_existing_file_manifest_records_d`,
`test_task_clear_never_existed_writes_nothing_no_d`,
`test_todo_clear_removes_pre_existing_file_manifest_records_d`,
`test_todo_clear_never_existed_writes_nothing_no_d`,
`test_task_write_only_headings_pre_existing_removed_manifest_records_d`,
`test_task_write_only_headings_never_existed_no_d`,
`test_todo_write_no_items_pre_existing_removed_manifest_records_d`,
`test_todo_write_no_items_never_existed_no_d`,
`test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w`,
`test_rename_only_manifest_present_empty_sentinel_written`,
`test_precompact_nothing_touched_manifest_still_written_empty`. `12 failed,
127 passed`. Target row confirmed among them, as predicted; the two rows
beyond the dispatch's own enumeration (`test_rename_only_…` and
`test_precompact_nothing_touched_…`) are the same mechanism reaching
`task_clear()`'s empty body through `_plan_file` in payloads the dispatch
text didn't name — consistent with the rule, not a surprise.

Restore: inverted the one-line replacement back to
`if lib.is_empty_body(body):`. `git diff --stat` empty; suite green
(`139 passed`).

### (c) Positive's second claim

Mutation — in `main()`, replaced
`manifest_lines = task_plan.manifest_lines + todo_plan.manifest_lines` with
`manifest_lines = todo_plan.manifest_lines  # MUTATION(c): task lines dropped`.

Reds (11): the target row
`test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` (on its
exact-two-lines assertion — manifest came back as `['W
.claude/handoff-todo.md']` vs the expected `['D .claude/handoff-task.md', 'W
.claude/handoff-todo.md']`) plus
`test_task_write_creates_file_manifest_records_w[handoff]`,
`test_task_write_creates_file_manifest_records_w[precompact]`,
`test_task_clear_removes_pre_existing_file_manifest_records_d`,
`test_todo_clear_removes_pre_existing_file_manifest_records_d`,
`test_todo_clear_never_existed_writes_nothing_no_d`,
`test_task_write_only_headings_pre_existing_removed_manifest_records_d`,
`test_todo_write_no_items_pre_existing_removed_manifest_records_d`,
`test_todo_write_no_items_never_existed_no_d`,
`test_todo_keep_leaves_pre_existing_list_alone`,
`test_task_and_todo_both_written_manifest_lists_both`. `11 failed, 128
passed`. Target row confirmed among them, as predicted.

Restore: inverted back to the concatenation. `git diff --stat` empty; suite
green (`139 passed`).

### (d) Existence sampling

Mutation — in `_plan_file`, the never-existed branch of the removal route
changed from `return FilePlan("none", path, "", [])` to
`return FilePlan("none", path, "", [f"D {rel}"])  # MUTATION(d): D unconditional`
— `act` stays `"none"` (no unlink attempted on an absent file), only the
manifest line changes.

Reds (6): the four named rows —
`test_task_clear_never_existed_writes_nothing_no_d`,
`test_todo_clear_never_existed_writes_nothing_no_d`,
`test_task_write_only_headings_never_existed_no_d`,
`test_todo_write_no_items_never_existed_no_d` — plus
`test_rename_only_manifest_present_empty_sentinel_written` and
`test_precompact_nothing_touched_manifest_still_written_empty` (same
`task_clear()`-on-an-absent-file mechanism as in (b)'s two extra rows). `6
failed, 133 passed`.

Checked the positive explicitly: neither
`test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` nor
`test_todo_edit_emptying_the_list_removes_it_manifest_records_d` appears in
the failure list — confirmed still green, as required (their fixtures'
task/todo files exist, so they take the `existed=True` removal branch, which
already emitted `D` before and after this mutation, so the mutation cannot
be observed there). All four named rows are genuinely the never-existed
ones — verified against their bodies (`make_repo` with no pre-write to the
target path) before running, not just inferred from the name.

Restore: inverted the `f"D {rel}"` back to `[]`. `git diff --stat` empty;
suite green (`139 passed`).

## End state

```
$ git status --porcelain
?? plans/2026-09-08-apply-before-mutate/reports/item-1-1-s1-green.md
$ git diff --stat scripts/checkpoint.py
$
```

Only this report is untracked; every mutation is restored.
