# Item 1.1 slice 1 — code review

Verdict: **accepted, no fixes applied.** Both declared departures are faithful
to the plan. The required mutation check discriminates exactly as the item
predicted. No critical, major or minor finding was found that warranted an
edit; three observations are recorded at the end, none of them a defect.

Reviewed at `e9f985f`. `scripts/checkpoint.py` and `tests/checkpoint.bats`
are unmodified by this review — `git status --short` shows only the untracked
report files under `plans/.../reports/`.

## Ruling on departure 1 — `unlink-if-present` scoped to the explicit `clear`

**Faithful. Slice 4 collapses it; it does not unpick it.**

The intermediate state is coherent. `apply_task` currently reads:

```python
    path = root / HANDOFF_REL_TASK
    if action == "clear":
        existed = path.is_file()
        if not existed:
            return []
        path.unlink()
        return [f"D {HANDOFF_REL_TASK}"]
    path.write_text(content, encoding="utf-8")
    if lib.is_empty_body(content):
        path.unlink()
        return [f"D {HANDOFF_REL_TASK}"]
    return [f"W {HANDOFF_REL_TASK}"]
```

The second existence discipline is not a *new* shape this slice introduced —
it is the pre-slice write path, byte-for-byte (`git show e9f985f` shows the
last four lines as unchanged context). Nothing was built around it; the `clear`
branch was inserted in front of it.

What slice 4 has to do is hoist one statement and make one return conditional:
`existed = path.is_file()` moves above the `if action == "clear":` line, and
the empty-body branch's `return [f"D …"]` becomes `return [f"D …"] if existed
else []`. The `clear` branch then *is* the tail of the shared removal route
and folds into it. In `apply_todo` the same hoist additionally serves the
`edit` route's own `path.is_file()` check, so it removes a stat rather than
adding one. That is a collapse, not a dismantling: no abstraction, no
duplicated logic, no call-site churn, no test outside slice 4's own two amended
rows.

The discipline argument holds too. The two rows that would pin the fuller D3
contract — `test_task_write_only_headings_removed_manifest_records_d` and
`test_todo_write_no_items_removed_manifest_records_d` — are still in their
pre-slice-4 form and still assert the unconditional `D` for a never-existed
file (read at `tests/test_checkpoint.py`, confirmed). Implementing past them
would have meant either editing slice 4's tests inside slice 1 or shipping
behaviour no test covers. Neither is what the runbook asks.

Note for slice 4, since it is not obvious from the diff: in the write route the
*disk* state is already correct for a never-existed empty body (the file is
written, then unlinked), so the only thing slice 4 changes there is the
manifest line. The `D` is the phantom; the file is not.

## Ruling on departure 2 — the `tests/checkpoint.bats` fixture repoint

**Faithful, minimal, and behaviour-preserving.**

One line changed, `handoff_payload()` at `tests/checkpoint.bats:212`:
`task:null, todo:null` → `task:{action:"clear"}, todo:{action:"keep"}`.

- It does not change what the rows test. `handoff_payload` has exactly one
  caller (line 219, `shim: bin/handoff-checkpoint execs the checkpoint,
  forwards stdin`), which asserts status 0 and that stdout names
  `$repo/.claude/gitlore-commit-memory` — the shim forwarding stdin and the
  memory directive reaching stdout, not payload semantics. The sibling row
  (`shim: … surfaces a schema violation`) sends the literal
  `{"commit":"with-commit"}` and is untouched by the schema change.
- It is behaviour-preserving, not merely green: in that fixture no
  `.claude/handoff-task.md` exists, so `clear` returns `[]` and `keep` returns
  `[]` — the same empty manifest the old `null, null` produced. Content strings
  would have been a larger change (they would write files); `clear`/`keep` is
  the minimal pair.
- No other bats fixture sends the retired shape. Grepped both `.bats` files for
  `task:null` / `todo:null` / `file_path`: the only `file_path` hits are in
  `tests/hook-test.bats`, all inside `tool_input:{file_path:…}` Write/Edit
  **tool** payloads (lines 557–735), not checkpoint JSON — which is what the
  recall artifact and the runbook already established.

## Mutation check — required, and it discriminates

Mutated in place (saved copy, mutated where it lives, restored from `HEAD`
after — the file was committed and otherwise untouched, so the restore is
exact). `apply_task`'s `clear` branch replaced with an unconditional `D`:

```python
    if action == "clear":
        path.unlink(missing_ok=True)
        return [f"D {HANDOFF_REL_TASK}"]
```

`pytest tests/test_checkpoint.py -k task_clear` → **1 failed, 1 passed**:

- `test_task_clear_never_existed_writes_nothing_no_d` — **FAILED**, on its own
  third assertion:
  `AssertionError: assert 'handoff-task.md' not in 'D .claude/handoff-task.md\n'`
- `test_task_clear_removes_pre_existing_file_manifest_records_d` — **PASSED**.

Exactly the split the item names its anti-vacuity device for: the pair differs
only in whether the file is pre-created, and only the never-existed half reds.
Restored, `git diff scripts/checkpoint.py` empty.

## Unchanged-file confirmations

- `apply_edit` — **identical**, function body diffed between `e9f985f^` and the
  working tree.
- `write_manifest` — **identical**, same method.
- `lib.is_empty_body` — `scripts/_checkpoint_lib.py` is **not in the commit at
  all** (`git show --name-only e9f985f` lists `pyproject.toml`,
  `scripts/checkpoint.py`, `tests/checkpoint.bats`, `tests/test_checkpoint.py`).

## Enumerated call sites — every one landed

- `validate_task` replaced whole; the `file_path` block and the
  `old_string`/`new_string` guard are gone.
- `_todo_file_path` **gone outright** — `grep -n '_todo_file_path\|file_path'
  scripts/checkpoint.py` returns **no hits at all**, so `file_path` is gone
  from both fields as well.
- `validate_todo`'s `has_content`/`has_old`/`has_new` sniffing collapsed to one
  `action` dispatch (`clear` / `keep` / `edit`, with `edit`'s two keys checked
  by presence and named individually).
- `apply_task` / `apply_todo` — `clear` is unlink-if-present with existence
  sampled first; see departure 1 for the scope.
- `main` drops `root` from both validate calls; both signatures are
  `(payload: JSONDict)`.
- Interfaces match verbatim: `validate_task -> tuple[str, str]`,
  `validate_todo -> tuple[str, str, str, str]`, `apply_task(root, action,
  content) -> list[str]`, `apply_todo(root, action, content, old, new) ->
  list[str]`.

### `main`'s boundary-skill gate

`if skill in ("handoff", "precompact"):` wraps all four calls;
`manifest_lines: list[str] = []` is initialised outside it and
`write_manifest(root, manifest_lines)` sits outside it, unconditional. The gate
opens no hole for the other two skills: `validate_autoname_forbidden_fields`
and `validate_restart_forbidden_fields` both list `"task"` and `"todo"` and
reject them by key presence, and both run before the gate. The two regression
rows are green (see below).

### `"clear"` and `"keep"` are not collapsed

`validate_todo` returns `("clear", "", "", "")` and `("keep", "", "", "")` as
distinct tuples; `apply_todo` returns `[]` for `keep` **before** it composes
`path` at all, and reaches the sampled-existence unlink only for `clear`.
`"none"` no longer appears anywhere in either function.

### FR2 — every message names the offending field

Probed the twelve cases slices 2 and 3 will pin, by running `checkpoint.py`
directly; every one exits 2 and every message's field prefix contains `task` or
`todo`:

| payload fragment | stderr |
|---|---|
| `"task": null` | `task: must be a content string or {"action": "clear"}, got null` |
| `task` key absent | `task: required, a content string or {"action": "clear"}` |
| `"todo": null` | `todo: must be a content string or an object naming an action, got null` |
| `todo` key absent | `todo: required, a content string or an object naming an action` |
| `task: {"action":"emty"}` | `task.action: must be "clear", got "emty"` |
| `task: {"action":"keep"}` | `task.action: must be "clear", got "keep"` |
| `task: {"action":"edit",…}` | `task.action: must be "clear", got "edit"` |
| `task: {}` | `task.action: required` |
| `task: 5` | `task: must be a content string or {"action": "clear"}, got number` |
| `todo: {"action":"edit","old_string":…}` | `todo.new_string: required for {"action": "edit"}` |
| `todo: {"action":"edit","new_string":…}` | `todo.old_string: required for {"action": "edit"}` |
| `todo: {"action":"emty"}` | `todo.action: must be "clear", "keep" or "edit", got "emty"` |

Every rejection raises out of `validate_*`, which runs before any `apply_*`, so
slice 2's "target file was not created" half is satisfied structurally.

### Conventions

- **No back-compat branch for the retired shape.** An object carrying
  `content`/`file_path` and no `action` is rejected (`task.action: required`);
  nothing accepts the old form.
- **No dead config.** The transient `[[tool.mypy.overrides]]` block is deleted
  from `pyproject.toml`, and `just precommit` is green without it — mypy and
  `ty check` both clean, which is the claim the deletion rests on.
- **No vestigial parameter.** `root` is gone from both validate signatures;
  `HANDOFF_REL_TASK`/`HANDOFF_REL_TODO` are still read by `apply_*`.
- **Entry points first.** `checkpoint.py` is bottom-up throughout (`err` at 59
  … `main` at 463) and was before this commit; the new definitions sit in their
  predecessors' slots. Not a change this slice introduced, so not a finding
  here.

## Verification, with the SUT restored

- `pytest tests/test_checkpoint.py` — **107 passed**.
- The three rows the dispatch named, run individually — **3 passed**:
  `test_drifted_cwd_writes_injected_root_never_cwd`,
  `test_autoname_manifest_present_empty_neither_file_touched`,
  `test_restart_manifest_present_empty_neither_file_touched`.
- `just precommit` — **green**: manifest + settings lint, `shellcheck -x`,
  ruff / docformatter / mypy / ty, `bats tests/hook-test.bats
  tests/checkpoint.bats` **159 ok**, `pytest` **197 passed, 11 deselected**.
- `git status --short` — only the untracked `reports/*.md`. No commit made.

## Observations — not findings, no edit made

1. **`{"action": null}` reports `task.action: required`.** `action =
   task.get("action")` then `if action is None` conflates an absent key with an
   explicit null one. Both name the field, so FR2 holds, and slice 3's
   enumerated cases do not include it. Changing it would add an untested
   branch for a message nuance; left alone deliberately.
2. **`edit`'s `old_string`/`new_string` are checked for presence, not type.** A
   number would reach `apply_edit` and raise a `TypeError` traceback rather
   than a named schema error. This is unchanged from before the commit (the
   old code `cast`-ed the same way), and slice 3 scopes itself to required
   keys, so it is not this slice's regression — recorded in case a later pass
   wants it.
3. **`task_content`/`todo_content` are now identity functions.** Deliberate per
   the runbook ("slices 2–4 read them as the single definition of the shapes"),
   and in the test file, which is outside this review's IN scope. Whether they
   survive Phase 4 is a decision for whoever closes the job.

No in-scope-unfixable refactoring to flag.
