# Item 1.1 slice 3 — write-then-mutate evidence

Mode: RED, adapted per the runbook's **write-then-mutate** form (the same
adaptation slice 2 used): every case slice 3 enumerates already exits 2
against the unchanged SUT, so no natural red is available. Evidence is a
mutation matrix instead of a RED/GREEN pair.

Scope respected: only `tests/test_checkpoint.py` was left changed.
`scripts/checkpoint.py` was mutated ten times, transiently, for evidence, and
restored exactly each time via `git checkout -- scripts/checkpoint.py` —
confirmed by `git diff scripts/checkpoint.py` being 0 lines after every single
restore, checked in the shell (not eyeballed), never stacked (each mutation
applied to a clean tree, one at a time, in its own mutate→run→restore cycle).

## The table as written

Replaced the three tests it restates
(`test_task_with_old_string_new_string_errors`,
`test_todo_only_old_string_errors`, `test_todo_only_new_string_errors`, then
at `tests/test_checkpoint.py:429-486`) with one parametrized table in the same
location, immediately before `test_malformed_json_errors_naming_payload`:

```python
@pytest.mark.parametrize(
    ("field", "value", "reason"),
    [
        ("task", {"action": "emty"}, 'got "emty"'),
        ("todo", {"action": "emty"}, 'got "emty"'),
        ("task", {"action": "keep"}, 'got "keep"'),
        (
            "task",
            {"action": "edit", "old_string": "a", "new_string": "b"},
            'got "edit"',
        ),
        ("task", {}, "required"),
        ("todo", {}, "required"),
        ("task", 42, "got number"),
        ("todo", 42, "got number"),
        ("todo", {"action": "edit", "new_string": "b"}, "old_string"),
        ("todo", {"action": "edit", "old_string": "a"}, "new_string"),
    ],
    ids=[
        "task_unknown_action",
        "todo_unknown_action",
        "task_keep_rejected",
        "task_edit_rejected",
        "task_no_action_key",
        "todo_no_action_key",
        "task_not_string_or_object",
        "todo_not_string_or_object",
        "todo_edit_missing_old_string",
        "todo_edit_missing_new_string",
    ],
)
def test_task_or_todo_action_vocabulary_errors_naming_field(
    tmp_path: Path, field: str, value: object, reason: str
) -> None:
    """Everything outside the union is a named error.

    Both fields dispatch on an `action` key, and `edit`'s own required keys
    are checked by the same dispatch: an unknown action, a missing `action`
    key, a value that is neither string nor object, `task` receiving a
    `todo`-only action (`keep`, `edit`), and `edit` missing either required
    key independently — each exits 2 naming the offending field and its own
    reason.

    `task_edit_rejected`, `todo_edit_missing_old_string` and
    `todo_edit_missing_new_string` restate, in action vocabulary,
    `test_task_with_old_string_new_string_errors` /
    `test_todo_only_old_string_errors` / `test_todo_only_new_string_errors` —
    the same contract reached through the dispatch instead of through
    key-combination sniffing on a bare object.
    """
    repo = make_repo(tmp_path)
    payload: dict[str, object] = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    payload[field] = value
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert field in result.stderr
    assert reason in result.stderr
```

The three "keep their assertions unchanged" rows
(`test_todo_edit_old_string_absent_errors`,
`test_todo_edit_old_string_ambiguous_errors`,
`test_todo_edit_requested_file_missing_errors`, now at
`tests/test_checkpoint.py:698,717,735`) were confirmed unedited — they already
use `todo_edit(...)` for payload construction, so no touch was needed. No
`skill` dimension was added: slice 2's table already parametrizes both
boundaries and pins `main`'s `if skill in ("handoff", "precompact")` gate, so
doubling this table's rows would add no discrimination the suite does not
already have. No case here was found reachable under only one skill.

## Passing baseline (starting state, not evidence)

```
$ pytest tests/test_checkpoint.py -k test_task_or_todo_action_vocabulary_errors_naming_field -v
task_unknown_action            PASSED
todo_unknown_action            PASSED
task_keep_rejected             PASSED
task_edit_rejected             PASSED
task_no_action_key             PASSED
todo_no_action_key             PASSED
task_not_string_or_object      PASSED
todo_not_string_or_object      PASSED
todo_edit_missing_old_string   PASSED
todo_edit_missing_new_string   PASSED
10 passed, 112 deselected
```

Full suite: `pytest tests/test_checkpoint.py -q` → **122 passed** (115 existing
+ 10 new − 3 deleted). `pytest tests/test_checkpoint.py --collect-only -q` →
**122 tests collected**, confirming the count from a run rather than by
arithmetic.

## Mutation matrix

Ten mutations, one rule each, applied to `scripts/checkpoint.py:264-319`
(`validate_task`/`validate_todo`), run against the ten-row table, then
restored. Each cycle: apply → `pytest -k
test_task_or_todo_action_vocabulary_errors_naming_field -q` → `git checkout --
scripts/checkpoint.py` → `git diff scripts/checkpoint.py | wc -l` (0 every
time).

| # | Mutation | Rule pinned | Rows reddened |
|---|---|---|---|
| M1 | task accepts `"keep"` too (`action in ("clear", "keep")`) | task's allow-list is exactly `clear` | `task_keep_rejected` only |
| M2 | task accepts `"edit"` too (`action in ("clear", "edit")`) | task's allow-list is exactly `clear` | `task_edit_rejected` only |
| M3 | task's final catch-all removed; any non-`null` action defaults to `clear` | the one line M1/M2 each surgically weaken | `task_unknown_action`, `task_keep_rejected`, `task_edit_rejected` (all three, together) |
| M4 | todo's final catch-all removed; any non-`null` action defaults to `keep` | todo's allow-list is exactly `clear`/`keep`/`edit` | `todo_unknown_action` only |
| M5 | task's `action is None` branch removed (falls to the generic message) | a missing `action` key is its own error (task) | `task_no_action_key` only |
| M6 | todo's `action is None` branch removed | a missing `action` key is its own error (todo) | `todo_no_action_key` only |
| M7 | task accepts `"number"` type as write content (`str(task)`) | non-string/non-object is rejected by type (task) | `task_not_string_or_object` only |
| M8 | todo accepts `"number"` type as write content | non-string/non-object is rejected by type (todo) | `todo_not_string_or_object` only |
| M9 | todo's `old_string` presence guard dropped | `edit` requires `old_string` independently | `todo_edit_missing_old_string` only |
| M10 | todo's `new_string` presence guard dropped | `edit` requires `new_string` independently | `todo_edit_missing_new_string` only |

Every row of the table reds under at least one mutation. M1/M2/M4/M5/M6/M7/M8/
M9/M10 are each disjoint — one mutation, one row — which is the discrimination
the runbook asked for: nine of the ten rules are pinned by a mutation that
reds exactly the row it targets and nothing else. M3 is the deliberate
exception: it reds three rows *together* by design, because it removes the
one line that M1 and M2 each surgically weakened in isolation — showing that
`task_unknown_action`, `task_keep_rejected` and `task_edit_rejected` all rely
on that single final `err()` call, while M1/M2 show each row is *also*
individually reachable by weakening just its own action. No case went
unexamined and no mutation reddened every row (the failure mode that would
prove the table cannot discriminate).

### Representative evidence (full output)

M1, `task_keep_rejected` (assertion failure, exit-code axis):

```
>       assert result.returncode == 2
E       AssertionError: assert 0 == 2
E        +  where 0 = CompletedProcess(...).returncode
```

M3, all three task rows in one run:

```
FAILED [...][task_unknown_action]
FAILED [...][task_keep_rejected]
FAILED [...][task_edit_rejected]
3 failed, 7 passed, 112 deselected
```

M9, `todo_edit_missing_old_string` — reds on exit code, not on message, since
dropping the presence guard turns a graceful `err()` into an uncaught
`KeyError`:

```
>       assert result.returncode == 2
E       assert 1 == 2
E        +  where 1 = CompletedProcess(..., returncode=1, stdout='',
           stderr='Traceback (most recent call last):\n...
           KeyError: \'old_string\'\n').returncode
```

M10 mirrors M9 exactly (dropping the `new_string` guard instead), confirmed
independently — `todo_edit_missing_old_string` stays green under M10 and
`todo_edit_missing_new_string` stays green under M9, which is the
"independently" half of the runbook's requirement for the two `edit`-key
checks.

All ten cycles' single-line summaries:

```
M1:  1 failed, 9 passed  (task_keep_rejected)
M2:  1 failed, 9 passed  (task_edit_rejected)
M3:  3 failed, 7 passed  (task_unknown_action, task_keep_rejected, task_edit_rejected)
M4:  1 failed, 9 passed  (todo_unknown_action)
M5:  1 failed, 9 passed  (task_no_action_key)
M6:  1 failed, 9 passed  (todo_no_action_key)
M7:  1 failed, 9 passed  (task_not_string_or_object)
M8:  1 failed, 9 passed  (todo_not_string_or_object)
M9:  1 failed, 9 passed  (todo_edit_missing_old_string)
M10: 1 failed, 9 passed  (todo_edit_missing_new_string)
```

## Restore confirmed

After each of the ten mutate/run/restore cycles (plus two additional
verbose-capture cycles for M1 and M9, twelve total):
`git checkout -- scripts/checkpoint.py` then `git diff scripts/checkpoint.py |
wc -l` — **0 every time**. Final check after the full matrix:
`git diff --stat scripts/checkpoint.py` — empty output. `scripts/checkpoint.py`
is unmodified in the working tree at the end of this dispatch.

## Verification

- `pytest tests/test_checkpoint.py -q` — **122 passed** (final run, unmutated
  SUT).
- `pytest tests/test_checkpoint.py --collect-only -q` — **122 tests
  collected**.
- `just precommit` — **green**: `shellcheck -x` clean, `ruff check`/`ruff
  format --check`/`docformatter --check`/`mypy`/`ty check` all clean,
  `bats tests/hook-test.bats tests/checkpoint.bats` → **159 ok**, `pytest`
  (whole suite) → **212 passed, 11 deselected** (the `live`-marked TUI
  conformance rows, per convention).
- `git status --short` — only `tests/test_checkpoint.py` modified (plus this
  report, untracked; `.claude/handoff-task.md` and `.claude/handoff-todo.md`
  were already staged before this dispatch and are unrelated to it).
- `git diff --stat scripts/checkpoint.py` — empty.

No commit made — leaving the new table in the working tree per the dispatch's
done criteria, for the orchestrator to commit after review.
