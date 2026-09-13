# Minors fix — deliverable review of 2026-09-08-apply-before-mutate

**Date:** 2026-09-13
**Input:** `plans/2026-09-08-apply-before-mutate/reports/deliverable-review.md`
**Commits:** `b22e11d` (review report), `f090b92` (the four fixes) — on `main`,
not pushed.

## m1 — `_plan_file` composes its own path

`scripts/checkpoint.py:412`. Signature is now
`_plan_file(root: Path, rel: str, body: str)`, with `path = root / rel`
composed inside (`:422`). `plan_task` passes `root` (`:438`); `plan_todo`
passes `root` (`:464`) and keeps its own local `path = root / HANDOFF_REL_TODO`
(`:450`), which its `keep` empty plan (`:452`) and its `edit` file-absent
precondition (`:456`) still need.

Two docstrings moved.

`_plan_file`'s gained one paragraph ahead of the existing prose (`:415-416`):

> Composes the path from `rel` rather than taking both, so the file a plan
> acts on and the file its manifest line names cannot disagree.

`FilePlan`'s (`:382-388`) changed from

> Every plan carrying a manifest line comes from _plan_file, so a plan cannot
> claim a `D` it will not perform; plan_todo's `keep` builds the empty plan
> directly, ahead of that resolver, because FR4 forbids it even a stat.

to

> Every plan carrying a manifest line comes from _plan_file, which composes
> the path from the same `rel` it writes into that line, so a plan cannot
> claim a `D` it will not perform — a structural property of the resolver
> rather than a convention its callers keep. plan_todo's `keep` builds the
> empty plan directly, ahead of that resolver, because FR4 forbids it even a
> stat.

## m2 — the unlink tolerates a file that vanished

`scripts/checkpoint.py:467-480`. `plan.path.unlink()` →
`plan.path.unlink(missing_ok=True)` (`:480`). The docstring's body changed
from

> No failure branch.

to

> Neither arm calls err(), and the unlink tolerates a file already gone — one
> removed between _plan_file's stat and this call would otherwise raise
> FileNotFoundError ahead of write_manifest, with the other half possibly
> applied, which is the outcome resolving both plans first exists to remove.
> The `D` line stays correct when that happens: the file is absent either way,
> so bash-post.sh's `git add -f` stages the deletion whoever performed it.

Summary line ("Perform the write or the unlink a plan names.") unchanged.

## m3 — the mirror row

`tests/test_checkpoint.py:1042`,
`test_todo_edit_old_string_absent_errors_task_file_not_created`, sitting
immediately after the three `…_task_file_survives` siblings and before
`test_todo_keep_leaves_pre_existing_list_alone`. Fixture: `make_repo`, no
pre-existing task file, a pre-existing todo file, `task_content(...)` carrying
a frame, `todo_edit("- not present", "- x")`. Asserts exit 2,
`todo.old_string` and `not found` on stderr, `not task_path.exists()`, the todo
file's bytes unchanged, and no `.claude/checkpoint-manifest`.

## m4 — "touches the disk" → "is written"

`CLAUDE.md:544`:

- before: `or not at all: nothing touches the disk until both plans exist. The`
- after:  `or not at all: nothing is written until both plans exist. The`

`docs/changelog/2026-09-13-nothing-is-written-until-both-halves-resolve.md:25`:

- before: `resolving. Only once both plans exist does anything touch the disk.`
- after:  `resolving. Only once both plans exist does anything get written.`

No `> **Superseded**` header added, nothing else touched in either passage, and
`docs/design.md` untouched.

## m3's knock-on in `CLAUDE.md`

Count re-derived, not incremented:

```
$ pytest tests/test_checkpoint.py --collect-only -q
140 tests collected in 0.47s
```

`CLAUDE.md:810`: `(139 tests)` → `(140 tests)`.

`CLAUDE.md:829-834`, the "Edit application" phrase:

- before: `(`old_string` absent, ambiguous, the file missing, successful — each of the three failures over the same fixture as the positive, and each asserting the task file survives with its original bytes and no manifest is written), and`
- after:  `(`old_string` absent, ambiguous, the file missing, successful — each of the three failures over the same fixture as the positive, and each asserting the task file survives with its original bytes and no manifest is written, plus the mirror of those three, where the task half carries content and is not created), and`

## Mutation check

Run after the commit, against the committed code, by editing
`scripts/checkpoint.py` in place: `main()`'s four statements reordered so
`apply_plan(task_plan)` runs immediately after `plan_task(...)` and before the
`plan_todo(...)` call.

```
$ pytest tests/test_checkpoint.py -q
FAILED tests/test_checkpoint.py::test_todo_edit_old_string_absent_errors_task_file_survives
FAILED tests/test_checkpoint.py::test_todo_edit_old_string_ambiguous_errors_task_file_survives
FAILED tests/test_checkpoint.py::test_todo_edit_requested_file_missing_errors_task_file_survives
FAILED tests/test_checkpoint.py::test_todo_edit_old_string_absent_errors_task_file_not_created
4 failed, 136 passed in 23.41s
```

The new row reds on its own assertion —
`assert not task_path.exists()` / `AssertionError: assert not True`
(`tests/test_checkpoint.py:1069`) — alongside the three siblings the review
predicted, and nothing else.

Restore and proof:

```
$ git checkout -- scripts/checkpoint.py
$ git status --porcelain
$ git diff --stat -- scripts/checkpoint.py
```

Both printed nothing.

## `just precommit`

Green both times — before the commits and again after the restore. Checks that
passed, in order, identical on both runs:

- `jq . .claude-plugin/plugin.json`
- `jq . hooks/hooks.json`
- `jq . .claude/settings.json`
- `shellcheck -x .bin/* bin/* scripts/*.sh tests/*.bats`
- `ruff check scripts tests` — All checks passed
- `ruff format --check scripts tests`
- `docformatter --check scripts/*.py tests/*.py`
- `mypy`
- `ty check` — All checks passed
- `bats tests/hook-test.bats tests/checkpoint.bats` — 164 rows, no `not ok`
- `pytest` — 230 passed, 11 deselected

No check needed a docstring silenced; the rewritten docstrings passed
`docformatter`, `mypy` and `ty` as written.

## Notes on the directive

Nothing in it was wrong. Three details worth recording:

- The directive's line numbers were the pre-edit ones and all four targets
  matched their quoted text exactly.
- The tree held exactly the five paths the directive predicted — four
  modifications plus the untracked review report. No unrelated change found,
  nothing staged beyond what each commit was told to stage.
- Bare `pytest` was not on PATH in this shell; every Python run above
  prepended `/Users/david/code/handoff/.venv/bin`, as the directive allowed.
