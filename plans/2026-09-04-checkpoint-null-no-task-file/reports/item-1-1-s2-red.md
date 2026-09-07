# Item 1.1 slice 2 — write-then-mutate evidence

Mode: RED, adapted per the runbook's **List revision (recorded 2026-09-07)**:
every case slice 2 enumerates already exits 2 against the current SUT
(`e9f985f`/`099fecd`), so no natural red is available. Evidence is a mutation
matrix instead of a RED/GREEN pair.

Scope respected: only `tests/test_checkpoint.py` was left changed.
`scripts/checkpoint.py` was mutated three times, transiently, for evidence,
and restored exactly each time — confirmed by `git diff scripts/checkpoint.py`
being empty (0 lines) after every restore, including after the final
re-verification pass below.

## The table as written

Inserted into the "Schema validation (FR2)" section, immediately after
`test_malformed_json_errors_naming_payload` (`tests/test_checkpoint.py:494`):

```python
@pytest.mark.parametrize(
    ("field", "shape"),
    [("task", "null"), ("task", "absent"), ("todo", "null"), ("todo", "absent")],
    ids=["task_null", "task_absent", "todo_null", "todo_absent"],
)
def test_task_or_todo_null_or_absent_errors_naming_field(
    tmp_path: Path, field: str, shape: str
) -> None:
    """D2: task/todo are each required by key presence, with no default.

    `null` and an absent key are distinct, named errors on both fields — the
    defect being fixed is an agent choosing a spelling that silently did the
    wrong thing, so both wrong spellings must fail loudly, and neither may
    write its target file before failing.
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
    if shape == "null":
        payload[field] = None
    else:
        del payload[field]
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert field in result.stderr
    target = "handoff-task.md" if field == "task" else "handoff-todo.md"
    assert not (repo / ".claude" / target).exists()
```

(The parametrize originally carried a `bool` `present` parameter; `ruff`
flagged `FBT001` on the positional bool in the function definition — no other
row in this file takes a bool positional, so this was a genuine new
violation, not a pre-existing exemption. Renamed to a `"null"`/`"absent"`
string `shape`, matching this file's own `("field", "value")` parametrize
idiom used elsewhere. Behavior is identical; re-ran the full mutation matrix
against the renamed version below rather than assuming the rename preserved
it.)

## Passing baseline (starting state, not evidence)

```
$ pytest tests/test_checkpoint.py -k test_task_or_todo_null_or_absent_errors_naming_field -v
tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[task_null] PASSED
tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[task_absent] PASSED
tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[todo_null] PASSED
tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[todo_absent] PASSED
4 passed, 107 deselected
```

Full suite: `pytest tests/test_checkpoint.py -q` → **111 passed** (107 existing
+ 4 new).

Regression guard, run individually as instructed:

```
$ pytest tests/test_checkpoint.py -k "test_autoname_manifest_present_empty_neither_file_touched or test_restart_manifest_present_empty_neither_file_touched" -v
tests/test_checkpoint.py::test_autoname_manifest_present_empty_neither_file_touched PASSED
tests/test_checkpoint.py::test_restart_manifest_present_empty_neither_file_touched PASSED
2 passed, 109 deselected
```

Both confirm green — the new rows do not over-reach into `autoname`/`restart`.

## Mutation matrix

Each mutation applied in place to `scripts/checkpoint.py` (backup saved to
`/tmp/checkpoint.py.orig`, restored via `cp` after each run, `git diff`
verified empty). Run twice each — once while designing the table (bool
`present` param) and once after the `ruff` rename to `shape` — with identical
results both times; the table below is the final (post-rename) run.

| Mutation | task_null | task_absent | todo_null | todo_absent |
|---|---|---|---|---|
| **A** — `null` accepted as an empty write (weakens the `null` rejection) | **RED** | green | **RED** | green |
| **B** — absent key falls back to a default (`{"action":"clear"}`/`{"action":"keep"}`), weakens D2's key-presence rule | green | **RED** | green | **RED** |
| **C** — `main` writes the target file before calling `validate_task`/`validate_todo` (apply-before-validate ordering) | **RED** | **RED** | **RED** | **RED** |

### Mutation A — the `null` rejection

```python
    ttype = _json_type(task)
    if ttype == "string":
        return "write", cast("str", task)
    if ttype == "null":  # MUTATION A
        return "write", ""
    if ttype == "object":
```

(mirrored in `validate_todo`, returning `"write", "", "", ""`). Result:
`task_null` and `todo_null` red (both mutation runs, identical); the two
absent-key rows stay green because they still hit the untouched `if "task"
not in payload: err(...)` guard. This is the pairing the runbook asked for —
it shows the `null` rows and the absent-key rows are testing distinct
mechanisms, not one check covering both.

```
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[task_null]
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[todo_null]
2 failed, 2 passed, 107 deselected
```

### Mutation B — the required-by-key-presence rejection

```python
    task = payload.get("task", {"action": "clear"})  # MUTATION B
```

(and `todo = payload.get("todo", {"action": "keep"})`), replacing the
`if "task"/"todo" not in payload: err(...)` guard outright. Result:
`task_absent` and `todo_absent` red; the two `null` rows stay green, because
`payload["task"] = None` still reaches the trailing `err("task", "must be a
content string or …, got null")`. This is D2's own discrimination: key
presence, not value emptiness — a single mutation redding all four would have
meant the table couldn't tell the two rules apart.

```
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[task_absent]
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[todo_absent]
2 failed, 2 passed, 107 deselected
```

### Mutation C — the ordering that makes "target not created" meaningful

```python
    manifest_lines: list[str] = []
    if skill in ("handoff", "precompact"):
        # MUTATION C: write the targets ahead of validation, simulating apply
        # running before validate.
        (root / HANDOFF_REL_TASK).write_text("stub", encoding="utf-8")
        task_action, task_content = validate_task(payload)
        (root / HANDOFF_REL_TODO).write_text("stub", encoding="utf-8")
        todo_action, todo_content, todo_old, todo_new = validate_todo(payload)
        manifest_lines = apply_task(root, task_action, task_content)
        ...
```

`validate_task`/`validate_todo` lost their `root` parameter in slice 1, so
neither function can write a file itself; the mutation instead moves the
write into `main`, ahead of each validate call, which is the concrete shape
"apply before validate" takes at this call site. Result: all four rows red —
`task_null`/`task_absent` because the task stub lands before `validate_task`
raises; `todo_null`/`todo_absent` because `validate_task` succeeds normally
(a well-formed `task_clear()` payload) and the todo stub then lands before
`validate_todo` raises. This confirms the "file not created" half of the
table is real evidence, not decoration — as the runbook warned it might turn
out to be if this mutation failed to red anything.

```
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[task_null]
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[task_absent]
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[todo_null]
FAILED tests/test_checkpoint.py::test_task_or_todo_null_or_absent_errors_naming_field[todo_absent]
4 failed, 107 deselected
```

No case in the table went unexamined by any mutation — every row reds under
at least one of the three, and the A/B pairing shows the two rejection rules
are independently exercised rather than collapsed into one check.

## Restore confirmed

After each of the (six, counting the design-time and re-verification passes)
mutate/run cycles: `cp /tmp/checkpoint.py.orig scripts/checkpoint.py`, then
`git diff scripts/checkpoint.py` — **empty every time** (`wc -l` → 0).
`scripts/checkpoint.py` is unmodified in the working tree at the end of this
dispatch.

## Verification

- `pytest tests/test_checkpoint.py -q` — **111 passed** (final run, unmutated
  SUT, table in its post-rename form).
- `ruff check tests/test_checkpoint.py` — all checks passed (after the
  `FBT001` fix).
- `ruff format --check tests/test_checkpoint.py` — already formatted.
- `mypy tests/test_checkpoint.py` — clean, exit 0.
- `git diff scripts/checkpoint.py` — empty.
- `git status --short` — only `tests/test_checkpoint.py` modified (plus this
  report, untracked).

No commit made — leaving the new tests in the working tree per the dispatch's
done criteria.
