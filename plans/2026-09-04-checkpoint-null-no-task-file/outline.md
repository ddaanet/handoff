# Outline — `"task": null` means "no task file"

Source brief: `plans/2026-09-03-brief-checkpoint-null-no-task-file.md`.
Classification: Moderate / Production — see `classification.md`.

## Scope

`"task": null`, and its documented sibling `"task": {"file_path": …,
"content": null}`, currently exit 0 and touch nothing. Both must mean **no task
file**: the file is removed and the removal staged, per **FR6** (*file present ⟹
content pending*). No new requirement — this is FR6 conformance.

**IN:** `scripts/checkpoint.py` (`validate_task`, and `apply_task`'s manifest
rule); `tests/test_checkpoint.py`; both SKILL.md bodies; `docs/design.md` +
a `docs/changelog/` entry.

**OUT:** `todo` semantics (decision 1 below), `write-stage.sh`, `bash-post.sh`,
`is_empty_body`, the sentinel composer/parser pair. No back-compat branch for
the old `null` meaning — user base of one, fix forward
(`no-transition-special-cases`).

## Decisions this outline applies (each is my human partner's to confirm)

1. **`todo` does not follow.** `null` there keeps meaning "not speaking about
   todo this call". FR5 gives the asymmetry independently: the task file is
   authored whole, so `null` can only mean absent; the todo file is
   incrementally edited and has the Edit form precisely so it can change
   without regeneration. `test_todo_null_untouched_list_left_alone` stands.
2. **`task` becomes required under `handoff`/`precompact`, by key presence.**
   Today an absent key and `null` are indistinguishable (`payload.get("task")`).
   Once `null` deletes, a call that simply *forgets* `task` silently destroys a
   git-tracked file — a new silent-destructive path of exactly the class this
   fix closes. Key-presence-required-with-no-default is already the house rule
   for `clear`, `compact`, `continue` and `rename`. `todo` stays optional,
   because its `null` is non-destructive. Both SKILL.md bodies already always
   emit `task`, so no caller changes.
3. **A `D` manifest line is emitted only when a file was actually removed** —
   applied uniformly, so `null` and `content: ""` are one code path. Today
   `apply_task` writes-then-unlinks unconditionally and always emits `D`; on a
   never-existed file that makes `bash-post.sh` run a `git add` that exits 128
   into its `2>/dev/null` (verified), so the manifest claims a deletion that
   never happened. The alternative — always emit `D`, keeping the two forms
   identically noisy — needs no change to `apply_task` but puts that dead
   `git add` on the common rename-only path.

## Per-file changes

### `scripts/checkpoint.py`

- `validate_task` (~264): the two `return "none", ""` branches (`task is None`
  at 267, `content: None` at 273) become `return "write", ""`, routing both
  into the existing empty-body delete path. Add the required-key check for
  `handoff`/`precompact` (decision 2), erroring by name per FR2.
- `apply_task` (~358): emit `D` only when a file was actually removed
  (decision 3). `content: ""` and the `null` forms share the branch.
- `validate_todo`/`apply_todo`: **unchanged**.

### `tests/test_checkpoint.py`

- Invert `test_task_content_null_no_file_path_noop` (~554) and
  `test_task_file_path_content_null_noop` (~572): the file is removed and the
  removal reaches the manifest when one existed. Rename off `_noop`.
- Add: `null` against a **pre-existing** task file removes it and records `D`
  (no test creates that file today — verified — so this path is currently
  uncovered).
- Amend `test_task_write_only_headings_removed_manifest_records_d` (~663): no
  file pre-existed, so under decision 3 it records no `D`. Split into the
  pre-existing case (records `D`) and the never-existed case (does not).
- Add: `task` key absent under `handoff` and under `precompact` errors naming
  the field; `task` still forbidden by key presence under `autoname`/`restart`.
- Filler tolerance: 61 payloads pass `"task": None` and none pre-create the
  file, so the delete is a no-op for them; the two that assert
  `manifest.stat().st_size == 0`
  (`test_rename_only_manifest_present_empty_sentinel_written` ~844,
  `test_precompact_nothing_touched_manifest_still_written_empty` ~900) stay
  green under decision 3 and would break under the alternative.

### `skills/handoff/SKILL.md` and `skills/precompact/SKILL.md`

State the asymmetry rather than leaving it inferred — as written both describe
`task` and `todo` identically, which is what produced the wrong call. `task`:
`null` means there is no task file, and the checkpoint removes any stale one.
`todo`: `null` means this call says nothing about the list, which is left as
the agent edited it. Keep NFR3 in view — replace wording, do not add a
paragraph.

### `docs/design.md` + `docs/changelog/2026-09-04-null-is-absence.md`

Changelog entry carries the write-time record: the observed failure (2026-09-02,
handoff 0.13.1 — a frame stating a finished release was still unpublished
survived into the next session), the two rejected approaches from the brief
(error on `null`; document the `""` workaround), and the three decisions above.
Design doc: the `null`-is-absence rule and the task/todo asymmetry belong beside
FR5/FR6 and the existing "**The task file is checkpoint-only; the todo file is
not**" decision. Present tense, no status stamp, no byte counts.

## Dependencies and phase shape

Strictly sequential, one slice: schema + apply are one behavioral change and
their tests red together. Suggested typing for `/runbook` — **tdd** for
`checkpoint.py` + `tests/test_checkpoint.py` (genuine red is available without
a stub: the inverted assertions fail against unchanged code), **inline** for the
two SKILL.md bodies and the docs.

## Verification

`just precommit` (lints, `shellcheck -x`, ruff/docformatter/mypy/ty, `bats
tests/*.bats` + `pytest`). The payload contract changes (`task` required,
`null` semantics) but neither output file's markdown shape does, so
`CLAUDE.md`'s breaking-change rule is not triggered on its own terms; the
release call is my human partner's.
