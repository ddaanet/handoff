# Item 1.1 slice 1 — test review (RED)

Verdict: **accepted with fixes applied**. One major finding on
`test_todo_keep_leaves_pre_existing_list_alone` and one minor consistency
finding, both fixed in place. No commit.

## Mechanical re-verification (run, not taken on the report's word)

- `pytest tests/test_checkpoint.py --collect-only -q` → **107 collected**. ✓
- `pytest tests/test_checkpoint.py -q` → **52 failed, 55 passed**, **0 ERROR**
  and no collection error. Matches the RED report.
- Each of the slice's five tests fails on its **own assertion**
  (`assert result.returncode == 0`), against the unchanged validator's
  `task: must be an object or null` / `task.file_path: required`. None
  PASSED, none ERRORed, none raised before its assertion:
  - `test_task_write_creates_file_manifest_records_w`
  - `test_task_clear_removes_pre_existing_file_manifest_records_d`
  - `test_task_clear_never_existed_writes_nothing_no_d`
  - `test_todo_write_creates_file_manifest_records_w`
  - `test_todo_keep_leaves_pre_existing_list_alone`
- `git status --short scripts/` → empty. `scripts/checkpoint.py` untouched. ✓
- Lint over the changed files and repo-wide type checks: `ruff check`,
  `ruff format --check`, `docformatter --check`, `mypy`, `ty check` — all
  clean, **with the `[[tool.mypy.overrides]]` block removed**, which is the
  claim that block's deletion rests on.

## Findings

### 1. MAJOR — `test_todo_keep_leaves_pre_existing_list_alone` did not test `keep` (fixed)

As dispatched it was `test_todo_null_untouched_list_left_alone` renamed with
its body unchanged, so it kept that row's weaker assertions:

```python
    assert "untouched" in (repo / ".claude" / "handoff-todo.md").read_text()
```

That is a substring against a fixture the test itself wrote, and it was the
row's **only** post-condition. Two states of the world it cannot fail in,
both of which the item's own `apply_todo` contract (`"keep"` returns `[]`
without touching the file) forbids:

- a `keep` that rewrote the file — appending, reordering, or truncating to
  anything still containing `untouched` — passes;
- a `keep` that emitted a `W .claude/handoff-todo.md` manifest line passes,
  because the manifest was never read. The manifest line is the *observable*
  half of "without touching the file", and it was entirely unpinned.

The slice text names both post-conditions verbatim ("asserts the file's bytes
are unchanged **and** the manifest names no todo line"); neither was present.
This is exactly the `green-is-not-evidence` "substring another line satisfies"
shape, one level in — the fixture supplied the token, so no change to
`apply_todo` could red it.

Fixed: the pre-existing body is bound to `before`, asserted by **exact
equality** after the run, and the manifest is asserted to name no
`handoff-todo.md` at all:

```python
    before = "## Remaining\n\n- untouched\n"
    (repo / ".claude" / "handoff-todo.md").write_text(before)
    ...
    assert (repo / ".claude" / "handoff-todo.md").read_text() == before
    assert (
        "handoff-todo.md" not in (repo / ".claude" / "checkpoint-manifest").read_text()
    )
```

A `keep` mapped to `clear` now reds on the `read_text()` raising; a `keep`
that rewrites reds on the equality; a `keep` that records a manifest line reds
on the third assertion. Still red at RED, on
`assert result.returncode == 0`.

### 2. MINOR — lone `encoding="utf-8"` in the new `clear` fixture (fixed)

`test_task_clear_removes_pre_existing_file_manifest_records_d` was the only
one of the file's 15 `write_text` sites passing `encoding=`, which also forced
the call across three lines. Normalized to the file's convention; it now fits
one line.

## Anti-vacuity checks that hold as written (no change needed)

- **The `clear` pair does its job.** The two rows are identical payload,
  identical `todo_keep()`, identical repo fixture, differing *only* in whether
  `.claude/handoff-task.md` is pre-created — the pairing property is in the
  fixture, not in a comment. Against an `apply_task` that emits `D`
  unconditionally, the never-existed row reds on
  `"handoff-task.md" not in manifest`; against one that never emits `D`, the
  pre-existing row reds on the `D` line; against one that does not unlink, the
  pre-existing row reds on `not …exists()`. Neither half can pass vacuously.
- **`test_task_clear_never_existed_writes_nothing_no_d` asserts both halves.**
  `(repo / ".claude" / "checkpoint-manifest").is_file()` **and** the absence of
  `handoff-task.md` in its text. The bare negative alone would pass against a
  missing manifest — a different defect, since `bash-post.sh` gates on the
  file's mere presence — and the positive assertion is what closes it. Its
  paired positive over the same fixture is its twin above, so the negative is
  not standing alone.
- **Both `_creates_file_manifest_records_w` rows now assert exact equality**
  against the payload string, via a `content` local shared by the payload and
  the assertion, so payload and assertion cannot drift apart. `is_file()`
  survives on the task row as an independent existence check.
- **Parallel values are mutually distinct.** The two `W` rows pin different
  content (`"## Current task\n\nreal content\n"` vs
  `"## Remaining\n\n- an item\n"`) and different manifest paths, so an
  exchanged task/todo predicate cannot pass either.

## Mechanical edits verified

- All five factories flipped; `repo` dropped from all five signatures; **no
  call site passes a path** (grepped for `task_content(repo|root|Path`,
  `todo_content(…`, `todo_edit(…` — no hits). 15 `*_content`/`todo_edit` call
  sites, matching the runbook's count. `task_content`/`todo_content` correctly
  kept as identity functions — slices 2–4 read them as the single definition
  of the shapes.
- **Exactly the eight named rows deleted**, no more, no fewer (diff's `-def`
  list): the four `{"content": null}` no-ops with their section header,
  `test_task_file_path_outside_claude_errors`,
  `test_todo_file_path_outside_claude_errors`,
  `test_todo_content_and_old_string_together_errors`,
  `test_drifted_cwd_task_path_under_cwd_rejected`. The remaining `-def` entries
  in the diff are the five factories and two moves/renames
  (`test_task_write_creates_file_manifest_records_w` relocated under the
  surviving section header; `test_todo_null_untouched_list_left_alone` renamed).
- Survivors present and unmodified: `test_task_with_old_string_new_string_errors`
  (429), `test_todo_only_old_string_errors` (449),
  `test_todo_only_new_string_errors` (468) — the three slice 3 restates, still
  carrying literal `file_path`/`old_string` dicts, and the only three
  `file_path` occurrences left in the file.
  `test_drifted_cwd_writes_injected_root_never_cwd` (223) present and routed
  through `task_content`.
- `[[tool.mypy.overrides]]` block and its whole comment gone from
  `pyproject.toml`; `mypy` is clean without it.
- No vestigial references to the removed forms: no `{"content": null}` prose,
  no `file_path` outside the three survivor rows, no stale section header.

## For the GREEN dispatch

`test_drifted_cwd_writes_injected_root_never_cwd` is **red at RED** — its
payload routes through `task_content`, like every other factory-carried
payload in the suite. The runbook's "must stay green" is a GREEN-phase
obligation; confirm it green after the implementation lands. Same for
`test_autoname_manifest_present_empty_neither_file_touched` and
`test_restart_manifest_present_empty_neither_file_touched`, which slice 2
names as the regression guard for `main`'s boundary-skill gate.

## Re-run after fixes

- 107 collected; **52 failed, 55 passed** — unchanged shape.
- All five slice tests still fail on `assert result.returncode == 0`.
- `ruff check` / `ruff format --check` / `docformatter --check` / `mypy` /
  `ty check` all clean.
- No commit; `scripts/` untouched.
