# Item 1.2 — write-then-mutate evidence

Mode: RED, run under the adapted **write-then-mutate** form (the same
adaptation slices 2/3 used for item 1.1): both residuals name rows whose
correct outcome is already produced by unchanged, correct code, so no natural
red is available. Evidence is a mutation matrix instead of a RED/GREEN pair.

Scope respected: only `tests/test_checkpoint.py` was left changed.
`scripts/checkpoint.py` was mutated twice, transiently, for evidence, and
restored exactly each time via `git checkout -- scripts/checkpoint.py` —
confirmed by `git diff --stat scripts/checkpoint.py` being empty after every
single restore, checked in the shell (not eyeballed), never stacked (each
mutation applied to a clean tree, one at a time, in its own
mutate→run→restore cycle).

## The four rows, amended

### Residual 1 — `precompact` must be shown to apply, not merely to validate

`test_task_write_creates_file_manifest_records_w` (`tests/test_checkpoint.py:568`)
and `test_todo_write_creates_file_manifest_records_w` (`tests/test_checkpoint.py:692`)
are each parametrized `@pytest.mark.parametrize("skill", ["handoff", "precompact"])`,
mirroring the shape slice 2's table already established for the null/absent
matrix. `precompact`'s envelope differs from `handoff`'s (no `rename`/`clear`,
takes `compact` instead), so the payload is built conditionally:

```python
payload: dict[str, object] = {
    "skill": skill,
    "commit": "with-commit",
    "continue": None,
    "task": task_content(content),
    "todo": todo_keep(),
}
if skill == "handoff":
    payload["rename"] = "T"
    payload["clear"] = False
else:
    payload["compact"] = False
```

The rest of each body (the write, the manifest-line assertion) is unchanged —
only the boundary now varies. `string`-valued `skill` parameter, not a bool, so
no `FBT001`.

### Residual 2 — two rows whose absence assertion was true over an empty manifest

`test_task_clear_never_existed_writes_nothing_no_d` (`tests/test_checkpoint.py:625`):
`todo` changed from `todo_keep()` (→ `[]`, contributing nothing to the
manifest) to `todo_content("## Remaining\n\n- an item\n")` (→ a real `W` line).
The body now asserts that line survives before asserting the task's absence:

```python
manifest = (repo / ".claude" / "checkpoint-manifest").read_text()
# The todo line proves the manifest is live, so the absence below is a claim
# about the task route rather than about an empty manifest.
assert "W .claude/handoff-todo.md" in manifest.splitlines()
assert "handoff-task.md" not in manifest
```

`test_todo_keep_leaves_pre_existing_list_alone` (`tests/test_checkpoint.py:845`,
approx): `task` changed from `task_clear()` (→ `[]`) to
`task_content("## Current task\n\nreal content\n")` (→ a real `W` line), same
shape:

```python
manifest = (repo / ".claude" / "checkpoint-manifest").read_text()
# The task line proves the manifest is live, so the absence below is a claim
# about the todo route rather than about an empty manifest.
assert "W .claude/handoff-task.md" in manifest.splitlines()
assert "handoff-todo.md" not in manifest
```

This row also keeps its original, real positive (`read_text() == before`) —
the runbook's own note that this is the milder of the pair.

Both fixes follow the exact shape slice 4's review applied to its own pair
(`item-1-1-s4-test-review.md`'s lead 2 fix): a second field whose `W` line
must survive, asserted before the absence.

## Passing baseline (starting state, not evidence)

```
$ pytest tests/test_checkpoint.py -k "test_task_write_creates_file_manifest_records_w or test_todo_write_creates_file_manifest_records_w or test_task_clear_never_existed_writes_nothing_no_d or test_todo_keep_leaves_pre_existing_list_alone" -v
test_task_write_creates_file_manifest_records_w[handoff]    PASSED
test_task_write_creates_file_manifest_records_w[precompact] PASSED
test_task_clear_never_existed_writes_nothing_no_d           PASSED
test_todo_write_creates_file_manifest_records_w[handoff]    PASSED
test_todo_write_creates_file_manifest_records_w[precompact] PASSED
test_todo_keep_leaves_pre_existing_list_alone                PASSED
6 passed, 120 deselected
```

Full suite: `pytest tests/test_checkpoint.py -q` → **126 passed**. `pytest
tests/test_checkpoint.py --collect-only -q` → **126 tests collected**,
confirming the count from a run rather than by arithmetic.

> **Corrected at review, 2026-09-07.** This paragraph originally read "122
> existing + 4 new rows from the two now-parametrized tests gaining a
> `precompact` case each". Both halves are wrong: `git show
> HEAD:tests/test_checkpoint.py` collects **124**, not 122, and two tests each
> gaining one `precompact` case is **+2**, not +4. 124 + 2 = 126, which is what
> the pasted deselect counts in this report already imply (`6 passed, 120
> deselected`). No row was lost: the `def test_*` name lists of `HEAD` and the
> amended file are identical.

## Mutation matrix

Two mutations, each targeting one residual, applied to `scripts/checkpoint.py`,
run against the affected rows, then restored. Each cycle: stash the amended
test file to recover the *unamended* rows → apply mutation → run against
unamended rows (before) → restore the amended test file → run again against
amended rows (after) → `git checkout -- scripts/checkpoint.py` →
`git diff --stat scripts/checkpoint.py` (empty every time).

| # | Mutation | Targets | Before (unamended rows) | After (amended rows) |
|---|---|---|---|---|
| M1 | Narrow `main`'s gate to `if skill == "handoff":` (`scripts/checkpoint.py:487`) | Residual 1 | green — unamended rows only ever ran `skill="handoff"`, unaffected | red — the two `precompact` halves; the two `handoff` halves stay green (see the correction below for what else M1 reds file-wide) |
| M2 | Empty the manifest of every `W` line: `apply_task`'s write branch returns `[]` instead of `[f"W {HANDOFF_REL_TASK}"]` (line 352), and `apply_todo`'s write/edit branch returns `[]` instead of `[f"W {HANDOFF_REL_TODO}"]` (line 388) | Residual 2 | green — this is the known pre-existing weakness the runbook named | red — both rows fail on the `assert "W ..." in manifest.splitlines()` line (see the correction below for what else M2 reds file-wide) |

Each mutation is disjoint in what it edits: M1 touches only the gate `main`
uses to decide whether to call
`validate_task`/`validate_todo`/`apply_task`/`apply_todo` at all; M2 touches
only the write-branch return values inside those apply functions. Neither
reddens every row — the failure mode that would prove the amended rows cannot
discriminate — and the before/after pairing for each mutation shows the
amendment is what changed the outcome, not an artifact of some unrelated suite
state.

> **Corrected at review, 2026-09-07.** This paragraph originally claimed
> "Neither mutation reddens a row outside its own target — M1's red set is
> exactly `{task_write[precompact], todo_write[precompact]}`; M2's red set is
> exactly `{task_clear_never_existed, todo_keep_leaves_pre_existing}`". That
> claim was never measured — only `-k`-filtered runs were made — and it does
> not reproduce. Against the full amended file:
>
> - **M1** reds **6**: the two targets plus
>   `test_task_or_todo_null_or_absent_errors_naming_field[{task_null,task_absent,todo_null,todo_absent}-precompact]`.
>   Those are slice 2's rows, which cover the *validation* half of the same
>   `main` gate — so their redding is correct, and is the reason residual 1 is
>   described as "the half slice 2 left open".
> - **M2** reds **12**: the two targets plus every other row that asserts a
>   `W` line — both `_w` rows at both boundaries, slice 4's four
>   `_pre_existing_`/`_never_existed_` rows,
>   `test_todo_edit_replaces_first_occurrence_stages_w`, and
>   `test_task_and_todo_both_written_manifest_lists_both`.
>
> Neither excess weakens the matrix: each mutation still reds its own target,
> each target was green before the amendment and red after, and no row is
> redded by every mutation. What the original sentence asserted was a
> full-suite property that no run in this dispatch established.

### Representative evidence (full output)

M1, before (unamended rows, mutation applied):

```
$ pytest tests/test_checkpoint.py -k "test_task_write_creates_file_manifest_records_w or test_todo_write_creates_file_manifest_records_w" -v
test_task_write_creates_file_manifest_records_w PASSED
test_todo_write_creates_file_manifest_records_w PASSED
2 passed, 122 deselected
```

M1, after (amended rows, same mutation still applied):

```
$ pytest tests/test_checkpoint.py -k "test_task_write_creates_file_manifest_records_w or test_todo_write_creates_file_manifest_records_w" -v
FAILED tests/test_checkpoint.py::test_task_write_creates_file_manifest_records_w[precompact]
FAILED tests/test_checkpoint.py::test_todo_write_creates_file_manifest_records_w[precompact]
2 failed, 2 passed, 122 deselected
```

(`test_todo_write_creates_file_manifest_records_w[precompact]`'s failure is a
`FileNotFoundError` reading `.claude/handoff-todo.md`, since under M1 neither
`apply_task` nor `apply_todo` ever runs for `skill="precompact"` — the file
was never written at all, confirming the gate is what is under test.)

M2, before (unamended rows, mutation applied):

```
$ pytest tests/test_checkpoint.py -k "test_task_clear_never_existed_writes_nothing_no_d or test_todo_keep_leaves_pre_existing_list_alone" -v
test_task_clear_never_existed_writes_nothing_no_d PASSED
test_todo_keep_leaves_pre_existing_list_alone      PASSED
2 passed, 122 deselected
```

M2, after (amended rows, same mutation still applied):

```
$ pytest tests/test_checkpoint.py -k "test_task_clear_never_existed_writes_nothing_no_d or test_todo_keep_leaves_pre_existing_list_alone" -v
FAILED tests/test_checkpoint.py::test_task_clear_never_existed_writes_nothing_no_d
FAILED tests/test_checkpoint.py::test_todo_keep_leaves_pre_existing_list_alone
2 failed, 124 deselected
```

```
>       assert "W .claude/handoff-task.md" in manifest.splitlines()
E       AssertionError: assert 'W .claude/handoff-task.md' in []
E        +  where [] = <built-in method splitlines of str object at 0x...>()
```

## Restore confirmed

After each of the two mutate/run/restore cycles: `git checkout --
scripts/checkpoint.py` then `git diff --stat scripts/checkpoint.py` — **empty
every time**. Final check after the full matrix: `git diff --stat
scripts/checkpoint.py` — empty. `scripts/checkpoint.py` is unmodified in the
working tree at the end of this dispatch.

## Verification

- `pytest tests/test_checkpoint.py -q` — **126 passed** (final run, unmutated
  SUT).
- `pytest tests/test_checkpoint.py --collect-only -q` — **126 tests
  collected**.
- `ruff check tests/test_checkpoint.py` — all checks passed.
- `ruff format --check tests/test_checkpoint.py` — already formatted.
- `mypy tests/test_checkpoint.py` — clean, no output.
- `just precommit` — **green**: manifest/settings/hooks.json `jq` checks,
  `ruff check`/`ruff format --check`/`docformatter --check`/`mypy`/`ty check`
  all clean, `bats tests/hook-test.bats tests/checkpoint.bats` → **159 ok**
  (`1..159`), `pytest` (whole suite) → **216 passed, 11 deselected** (the
  `live`-marked TUI conformance rows, per convention).
- `git status --short` — only `tests/test_checkpoint.py` modified (plus this
  report, untracked).
- `git diff --stat scripts/checkpoint.py` — empty.

No commit made — leaving the amended rows in the working tree per the
dispatch's done criteria, for the orchestrator to commit after review.
