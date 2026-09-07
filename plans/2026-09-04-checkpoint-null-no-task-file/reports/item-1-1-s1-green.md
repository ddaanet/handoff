# Item 1.1 slice 1 report — GREEN

## Commit

`e9f985f` — "Item 1.1/1 — external contract, the union is accepted and applied"
(subject exactly as required). Carries `scripts/checkpoint.py`,
`tests/test_checkpoint.py`, `pyproject.toml`, and (see "Departure from the
enumerated call sites" below) `tests/checkpoint.bats`.

## What changed in `scripts/checkpoint.py`

- `validate_task(payload) -> tuple[str, str]` — replaced whole. Dispatches on
  the value's JSON type: a string is `("write", content)`; an object with
  `{"action": "clear"}` is `("clear", "")`; any other object shape (missing
  `action`, an unknown `action`, or the old `old_string`/`new_string` keys)
  errors naming `task`/`task.action`; `null` or an absent key falls through to
  the same "must be a content string or …" error naming `task`. No `root`
  parameter — `file_path` is gone.
- `validate_todo(payload) -> tuple[str, str, str, str]` — same shape, four
  actions: `write` (string), `clear`, `keep`, `edit` (requires both
  `old_string` and `new_string`, each checked by key presence and named
  individually if missing). `_todo_file_path` deleted outright.
- `apply_task(root, action, content) -> list[str]` — `"clear"` samples
  `path.is_file()` before touching anything and unlinks only if it was there,
  emitting `D` only on an actual removal. The write path (action `"write"`,
  including a body that reduces to empty under `is_empty_body`) is unchanged
  from before this slice: write, then check, unlink+`D` unconditionally if
  empty. See the departure note below for why.
- `apply_todo(root, action, content, old, new) -> list[str]` — `"keep"`
  returns `[]` immediately, touching nothing. `"clear"` mirrors `apply_task`'s
  sampled-existence unlink. `"write"`/`"edit"` keep their pre-slice shape
  (write/edit, then check emptiness of what's now on disk, `D` unconditional).
- `main()` — the two validate/apply pairs are now gated:
  `if skill in ("handoff", "precompact")`, with `manifest_lines` defaulting to
  `[]` outside that branch. `write_manifest` stays unconditional.

## The three named rows

All three confirmed green individually
(`pytest tests/test_checkpoint.py -k "..." -v`):

- `test_drifted_cwd_writes_injected_root_never_cwd` — **PASSED**.
- `test_autoname_manifest_present_empty_neither_file_touched` — **PASSED**.
- `test_restart_manifest_present_empty_neither_file_touched` — **PASSED**.

## Full suite

`pytest tests/test_checkpoint.py` — **107 collected, 0 failed** (built up test
by test; the only friction was the departure noted below).

## `just precommit`

**Green**, full output captured. Confirms the deleted
`[[tool.mypy.overrides]]` block (removed in the RED slice) is genuinely dead
config — `mypy`/`ty check` pass with no overrides needed, since both factories
now return dicts rather than `None`. `bats tests/hook-test.bats
tests/checkpoint.bats` — 159 ok, 1 initially failed (see below), then green.
Final `pytest` run (full suite, 208 collected / 197 selected): 197 passed.

## Departure from the item's enumerated call sites

Two departures, both required to reach the stated Done criteria without
weakening any assertion:

1. **`apply_task`/`apply_todo`'s "unlink-if-present" applies only to the new
   explicit `clear` action, not yet to the write-path's empty-body case.**
   The item's Interfaces block describes the full, final contract
   (`D` "only when a file was actually removed" for both routes to removal),
   but two pre-existing, not-yet-amended tests —
   `test_task_write_only_headings_removed_manifest_records_d` and
   `test_todo_write_no_items_removed_manifest_records_d` — still assert the
   old unconditional "write then unlink, `D` always" behavior for a
   never-existed file, because the runbook's own Slice 4 ("An empty body
   still removes, and `D` still records only a real removal") is what amends
   these two into pairs; that hasn't run yet. Implementing the full D3
   contract now made both fail. Per the runbook's own item text this pairing
   is explicitly Slice 4's job, and the GREEN dispatch's scope excludes
   writing or altering slices 2–4's coverage, so I left the write-path's
   emptiness handling exactly as it was (write, check, unlink+`D`
   unconditionally) and confined the new sampled-existence behavior to the
   `clear` action alone — the only piece slice 1's own tests exercise. This
   is a narrower cut of Item 1.1's D3 than the Interfaces block's final-state
   description, deliberately deferred rather than papered over; Slice 4's
   dispatch will need to extend the same sampled-existence pattern to the
   write path when it amends those two tests.

2. **`tests/checkpoint.bats`'s shim fixture repointed at the new payload
   shape.** `handoff_payload()` (line 212) built
   `{..., task: null, todo: null}`, which validated as a no-op under the old
   schema and now errors (`task`/`todo`: null is no longer accepted). This
   file is outside Item 1.1's stated scope (`tests/test_checkpoint.py` is the
   only test file named), but its one affected row —
   `shim: bin/handoff-checkpoint execs the checkpoint, forwards stdin` — is
   part of `just precommit`'s `bats tests/hook-test.bats tests/checkpoint.bats`
   step, a Done criterion. Repointed the one line to
   `task:{action:"clear"}, todo:{action:"keep"}` — mechanically equivalent to
   what Phase 0 already did throughout `test_checkpoint.py`'s factories, not
   new coverage. No other `checkpoint.bats` row touches `task`/`todo`.

Both departures are included in the slice commit since `just precommit` must
be green at every commit and the suite (Python + bats) could not reach green
without them.
