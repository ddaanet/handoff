# Phase 0 corrector report — payload factories

Reviewed: `247eba6` + `acfed1c` (`git diff e370aed..HEAD`). Verdict: the
refactoring is sound and behaviour-preserving. Two fixes applied, both minor,
both about Phase 1 reachability rather than about Phase 0's own correctness.

## Verification performed

**Counts, re-derived against the file rather than from the report.** Baseline
from `git show e370aed:tests/test_checkpoint.py`: 61 `"task": None`, 57
`"todo": None`, 11 `task_write` occurrences (10 call sites + the `def`).
After the phase, and after my own fix:

| bucket | expected | in file |
|---|---|---|
| `task_clear()` call sites | 61 | 61 |
| `todo_keep()` call sites | 57 | 57 |
| `task_content(` call sites | 4 (+2 from my fix) | 6 |
| `todo_content(` call sites | 3 (+2 from my fix) | 5 |
| `todo_edit(` call sites | 4 | 4 |
| `task_write` as a callable | 0 | 0 (survives only inside two test *names*) |

`grep -n '"task": None\|"todo": None'` returns nothing — no `None` site was
missed.

**No site was converted that should have stayed literal.** `grep -n '"task":\|"todo":\|("task",\|("todo",'` filtered against
the five factory names leaves exactly 11 sites, and they are exactly the
runbook's left-literal set: the three wrong-`file_path` rows
(`test_drifted_cwd_task_path_under_cwd_rejected`,
`test_task_file_path_outside_claude_errors`,
`test_todo_file_path_outside_claude_errors`), the four `{"content": None}`
no-op rows, and the four malformed key-combination dicts. Seven are deleted by
Phase 1; four are unrepresentable by construction.

**Every non-mechanical conversion read line by line.** I filtered the
`None`→factory swaps out of the diff and read the remaining 15 conversions
individually. All are byte-identical to what they replaced: the task-file
`task_write` sites went to `task_content`, the todo-file ones to
`todo_content` (none crossed over), the four `test_todo_edit_*` dicts to
`todo_edit` preserving `old`/`new`, and the `# noqa: S108` comment survived on
the `/tmp/not-the-project` literal.

**The one-line payload that was reformatted lost nothing.** My first pass at
the diff appeared to show `test_skill_missing_errors_naming_skill`'s
`payload = {"commit": …, "rename": "T", "task": None, "todo": None}` losing
both fields; that was my own grep filter hiding the added
`"task": task_clear(),` / `"todo": todo_keep(),` lines. Re-read at `-U6`: the
multi-line reformat preserves all four keys.

**Factory signatures match the runbook's stated interfaces exactly**, including
`task_clear() -> None` and `todo_keep() -> None`.
`str(repo / ".claude" / "handoff-task.md")` is the same string as the
runbook's `str(repo / ".claude/handoff-task.md")`.

**`test_drifted_cwd_writes_injected_root_never_cwd` passes `root`, not
`repo`** — `task_content(root, "## Current task\n\nbody\n")`, with
`run_checkpoint(elsewhere, payload, root=root)`. The mutation-checked negative
is intact: the assertions still require the write to land under `root` and
require `elsewhere/.claude/` to hold neither the task file nor the manifest.

## Judgment call 1 — the `pyproject.toml` mypy override: accepted as correct

**Correctly scoped, and live.** Mutation-checked rather than taken on trust: I
removed the block verbatim and ran `mypy`, which produced
`error: "task_clear" does not return a value (it only ever returns None)
[func-returns-value]` at every affected call site and nothing else, then
restored the file. So the module name `test_checkpoint` does resolve (`tests/`
is a flat directory under `files = ["scripts", "tests"]`, no package prefix)
and the override is not inert. Both axes are narrow: one module, one error
code.

**A narrower alternative existed but is worse.** Annotating the two factories
`-> object` instead of `-> None` satisfies mypy with no config change at all
and keeps Item 0.1's diff to the one file its Done criteria named. It was
rejected here because it contradicts the runbook's explicitly stated
interface (`task_clear() -> None`), and it buys a less precise return type for
two functions that exist for exactly nine more days of work. The remaining
alternatives are worse still: `# type: ignore[func-returns-value]` on ~118
sites, or an unannotated factory (which `strict` rejects under
`no-untyped-def`).

**Residual risk of the override, stated rather than implied:** it also
suppresses `func-returns-value` for any *other* `-> None` helper in
`test_checkpoint.py` used in expression position — `add_unidentified_sdd_ledger`,
`dirty_memory` and the like. A genuine `x = dirty_memory(repo)` slip would go
unflagged. That window closes with the block in Item 1.1.

**One fix applied.** The inline comment explained why the error is suppressed
but not that the suppression is temporary. Transience is the load-bearing
fact — an override whose only removal record lives in a plan file is one the
next reader of `pyproject.toml` has no way to know is dead. Extended the
comment by one sentence naming Item 1.1 and the runbook path, so the config
enforces its own removal:

```
# intentional one. Transient: Item 1.1 of
# plans/2026-09-04-checkpoint-null-no-task-file/runbook.md turns both factories
# into dicts, after which this block is dead config and must be deleted.
```

The block itself is untouched and precommit is green with it in place.

## Judgment call 2 — the four parametrize entries: reasoning holds, fixed anyway

The four sites are `("task", {"file_path": "/x/.claude/handoff-task.md",
"content": "body"})` and its `todo` twin, in each of
`test_every_boundary_field_is_schema_error_under_autoname` (1434–1435) and
`test_every_boundary_field_is_schema_error_under_restart` (1546–1547).

**The executor's reasoning about correctness is right.** These rows are
rejected by key presence under a skill that forbids the field, so the value is
never parsed, and Phase 1's `if skill in ("handoff", "precompact")` gate keeps
it that way. Better: each row asserts the skill's own name is in stderr
(`"autoname" in result.stderr`, `"restart" in result.stderr`) and explicitly
rules out the generic unknown-skill message, so a rejection that came from
`validate_task` complaining about the *value* would not satisfy the
assertion — the row cannot silently start passing for the wrong reason.

**But leaving them literal costs Phase 1 something the executor did not
weigh.** Two things, and the second is the one that decided it:

1. After Item 1.1 removes `file_path` from the schema, these four dicts are the
   only place in the suite still depicting that shape — vestigial residue of
   exactly the kind `remove-cleanly-no-vestigial` names, surviving with no red
   to announce it, in an item whose enumerated call-site list does not mention
   them.
2. A forbidden-field row only discriminates "rejected because the key is
   present" from "rejected because the value is malformed" when its value is
   *valid in itself*. Today's dict is valid; post-Item-1.1 it is not. The
   stderr assertions still carry the discrimination, but by construction rather
   than by the payload, which is a weaker place for it to live.

**Fixed.** Routed all four through the factories:

```python
("task", task_content(Path("/x"), "body")),
("todo", todo_content(Path("/x"), "body")),
```

Byte-identical today — asserted, not assumed: `str(Path("/x") / ".claude" /
"handoff-task.md") == "/x/.claude/handoff-task.md"`. At Item 1.1's flip they
become `task_content("body")` → `"body"`, a well-formed union value, and no
`file_path` shape survives anywhere.

**Runbook updated to match**, since the mapping asserted itself exhaustive and
Item 1.1 counts these sites:

- Item 0.1's mapping gains a sixth bucket recording the four entries and why
  they were missed (neither `None` nor a `task_write(...)` call, so neither
  grep that produced the counts reached them).
- Item 1.1's "bounded edit — the 11 content/edit call sites (7 `*_content`, 4
  `todo_edit`)" is now **15 (11 `*_content`, 4 `todo_edit`)**, with the old
  figure noted. Verified against the file: 6 `task_content` + 5
  `todo_content` = 11, plus 4 `todo_edit`.

## Nothing else found

No other issue at any severity. In particular: the factories are defined next
to the other payload helpers rather than front-loaded above their users; the
`task_write` deletion is complete; and no test's assertions were touched, only
its payload construction — which is the whole property that makes Phase 0's
green meaningful.

## Verification output

`pytest tests/test_checkpoint.py --collect-only -q` → **113 tests collected**,
unchanged from before the phase.

```
$ pytest tests/test_checkpoint.py -q
........................................................................ [ 63%]
.........................................                                [100%]
113 passed in 19.14s
```

```
$ just precommit
[... manifest + settings lint, shellcheck -x, ruff, ruff format --check,
     docformatter, mypy, ty, then bats tests/hook-test.bats tests/checkpoint.bats:
     159 bats assertions ok ...]
collected 214 items / 11 deselected / 203 selected

tests/test_checkpoint.py ............................................... [ 23%]
..................................................................       [ 55%]
tests/test_drive_when_idle.py ..............................             [ 70%]
tests/test_watcher_lib.py .............................................. [ 93%]
...                                                                      [ 94%]
tests/test_worktree_root.py ...........                                  [100%]

===================== 203 passed, 11 deselected in 45.15s ======================
ok
```

Checks that passed: plugin manifest lint, settings lint, `shellcheck -x`,
ruff, `ruff format --check`, docformatter, mypy (strict), ty, 159 bats rows,
203 pytest rows. No `--no-verify` anywhere; nothing committed.

## Files changed by this review

- `/Users/david/code/handoff/tests/test_checkpoint.py` — four parametrize
  entries routed through `task_content`/`todo_content`.
- `/Users/david/code/handoff/pyproject.toml` — one sentence added to the mypy
  override's comment recording its transience.
- `/Users/david/code/handoff/plans/2026-09-04-checkpoint-null-no-task-file/runbook.md`
  — Item 0.1 mapping gains the sixth bucket; Item 1.1's call-site count
  corrected 11 → 15.
