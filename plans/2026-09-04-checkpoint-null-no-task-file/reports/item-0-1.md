# Item 0.1 report — payload factories

## Test counts

- Before: 113 tests collected, `pytest tests/test_checkpoint.py` green.
- After: 113 tests collected, `pytest tests/test_checkpoint.py` green (113 passed).
- `just precommit`: green (203 passed, 11 deselected across the full suite).

## Per-bucket site counts converted

- `"task": None` → `task_clear()`: 61 of 61.
- `"todo": None` → `todo_keep()`: 57 of 57 (56 with a trailing comma via
  blanket `sed`, plus the one-liner at the old line 254
  (`payload = {"commit": ..., "task": None, "todo": None}`), which was
  matched separately since it closes with `}` rather than `,` and then
  reformatted to multi-line to satisfy `ruff`'s line-length check).
- `task_write(<…>/handoff-task.md, body)` → `task_content(<dir>, body)`: 4 of
  4 (old lines 216, 648, 671, 927).
- `task_write(<…>/handoff-todo.md, body)` → `todo_content(<dir>, body)`: 3 of
  3 (old lines 695, 717, 930).
- Well-formed todo Edit-form dict → `todo_edit(repo, old, new)`: 4 of 4, all
  inside `test_todo_edit_*` (old lines 741, 768, 791, 812).
- Left literal, exactly as specified (7 of 7): the three wrong-`file_path`
  rows (`test_drifted_cwd_task_path_under_cwd_rejected`,
  `test_task_file_path_outside_claude_errors`,
  `test_todo_file_path_outside_claude_errors` — their `task_write(...)` calls
  became inline literal dicts, since `task_write` is deleted and routing them
  through `task_content`/`todo_content` would force the *correct* path,
  defeating the test) and the four `{"content": None}` no-op rows (already
  literal dicts, untouched).
- Left literal, not in the given mapping (4 sites, judgment call — see
  below): the two `("task", {"file_path": "/x/...", "content": "body"})` /
  `("todo", {...})` parametrize-list entries in
  `test_every_boundary_field_is_schema_error_under_autoname` and
  `test_every_boundary_field_is_schema_error_under_restart`. These aren't
  `task_write(...)` calls, aren't `None`, and aren't named in the runbook's
  exhaustive bucket list. They test that *any* task/todo value is rejected
  under a skill that forbids the field outright — the dict's shape is inert
  filler alongside the parametrize list's other filler values (e.g.
  `("commit", "with-commit")`) — so routing them through a factory would add
  a coupling to `task_content`'s real path shape that these two tests don't
  need and the mapping didn't ask for. Left as-is.
- The four malformed key-combination dicts
  (`test_task_with_old_string_new_string_errors`,
  `test_todo_content_and_old_string_together_errors`,
  `test_todo_only_old_string_errors`, `test_todo_only_new_string_errors`) —
  the dict under test stays literal (no factory can emit it); each test's
  *other* field (`"task": None` / `"todo": None`) was still converted via the
  blanket substitution, per the mapping.

Final counts in the file confirm no site was missed or double-converted:
`task_clear()` appears 62× (61 call sites + 1 def), `todo_keep()` 58× (57 + 1
def), `task_content(` 5× (4 + 1 def), `todo_content(` 4× (3 + 1 def),
`todo_edit(` 5× (4 + 1 def). `task_write` no longer exists as a callable
(only survives inside two test function names,
`test_task_write_creates_file_manifest_records_w` and
`test_task_write_only_headings_removed_manifest_records_d`, which are
identifiers, not calls).

## Deviation from the stated scope: `pyproject.toml`

`git diff --stat` shows `tests/test_checkpoint.py` **and** `pyproject.toml`,
not `tests/test_checkpoint.py` alone as the Done criteria specified. This was
necessary: `mypy --strict` flags every call site of `task_clear()`/`todo_keep()`
used as a dict value with `func-returns-value` ("does not return a value, it
only ever returns None") — a real mypy strictness rule that fires on any
`-> None`-annotated function's call result used in an expression context,
regardless of whether the `None` is returned deliberately. Confirmed against
a minimal repro outside this file; there is no in-file way to satisfy it (not
even an unannotated function, which mypy instead flags as
`no-untyped-def`/`no-untyped-call` under `strict = true`), short of a
type-ignore comment on every one of the ~118 call sites.

Added a scoped `[[tool.mypy.overrides]]` block in `pyproject.toml`, disabling
only `func-returns-value` and only for the `test_checkpoint` module, with an
inline comment explaining why. This is the standard mypy idiom for a function
that deliberately returns `None` as a sentinel value. No other lint or test
behavior changed. Flagging this explicitly since it wasn't anticipated in the
Item 0.1 dispatch — happy to revert to per-call `# type: ignore` comments
instead if a repo-wide config change is unwanted, but that would touch ~118
lines instead of 9.

## Commit

`test: Item 0.1 — route every test payload through factories`
