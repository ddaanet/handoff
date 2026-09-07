# Item 1.1 slice 4 — code review

Verdict: **accepted with fixes applied.** The implementation at `2ee1fbf` is
behaviourally correct — every route to a `D` line is now guarded by an
existence sample taken before any write, and I could not construct a path on
which that sample is stale. Two fixes applied, both in
`scripts/checkpoint.py`: the two docstrings, which scoped to `clear` a
guarantee that is now the function's whole contract, and the dead
write-then-unlink in `apply_task`, which `existed` being available before the
write made removable.

`just precommit` green after the fixes: `shellcheck -x`, manifest/settings
lint, ruff + `ruff format --check` + docformatter + mypy + ty all clean,
`bats` **1..159**, `pytest` **214 passed, 11 deselected**. Working tree carries
`scripts/checkpoint.py` and this report; **no commit**.

## Findings

### 1. Major — both docstrings under-described the code (fixed)

`apply_task`'s said "`clear` is unlink-if-present: existence is sampled before
any write, and a `D` line records only a removal that actually happened",
scoping to one branch a property this slice made true of the write route as
well — which is the entire point of the slice. `apply_todo`'s had the same
shape ("`clear` is unlink-if-present, existence sampled before any write") and
also failed to say why its sample sits *below* the `keep` branch rather than at
the top.

Both rewritten to state the contract the code now has: both routes to removal
are one unlink-if-present, and a `D` records only a removal that happened. The
`apply_todo` one additionally names the two asymmetries against `apply_task`,
since a reader comparing them will otherwise read each as an accident —
`keep` must not even stat the file, and the emptiness test reads the file
rather than `content` because an `edit`'s result exists only on disk.

### 2. Major — the empty-body write route wrote a file only to unlink it (fixed, `apply_task` only)

Pre-existing, not introduced by this slice, and the disk state was correct
either way. But `apply_task` tests `lib.is_empty_body(content)` — the argument,
not the file — so with `existed` now sampled before the write, the write was
provably dead work: nothing between the `write_text` and the `unlink` reads the
path, and `main` never reads it after `apply_task` returns (`checkpoint.py:486`
uses only the returned manifest lines). Collapsed to:

```python
    path = root / HANDOFF_REL_TASK
    existed = path.is_file()
    if action == "clear" or lib.is_empty_body(content):
        if not existed:
            return []
        path.unlink()
        return [f"D {HANDOFF_REL_TASK}"]
    path.write_text(content, encoding="utf-8")
    return [f"W {HANDOFF_REL_TASK}"]
```

This is the shape the outline's decision 3 describes — "*this covers both
routes to removal … in one shape*" — reached literally rather than by two
branches that agree. The `clear` branch *is* the tail of the shared removal
route, as slice 1's review put it; the empty-body write is now the same route's
other entrance rather than a second copy of its ending.

The only observable difference is on a path that already fails: if
`$root/.claude/` does not exist, an empty task body used to raise inside
`apply_task`'s `write_text` and now raises a few lines later in
`write_manifest`, which writes into the same missing directory unconditionally.
Both are the same unhandled traceback and the same exit status; nothing
depended on which line produced it.

**Not applied to `apply_todo`, deliberately.** There the emptiness test is
`lib.is_empty_body(path.read_text(...))`, and for the `edit` route the result
is only on disk, so the read-back is load-bearing and the tail is genuinely
shared between `write` and `edit`. Skipping the `write` route's write would
need a second `is_empty_body(content)` test beside the tail's — trading one
redundant write for a duplicated predicate, which is the worse of the two. The
docstring now says why the two functions differ, which is the part that was
missing.

## The leads, answered

**Lead 2 — is `existed` stale at the `edit` guard? No.** Traced by branch
structure, not by the suite. Between `existed = path.is_file()` and
`elif action == "edit"` the only statements are the `clear` block (which
returns on both of its arms) and `if action == "write"`, which cannot be taken
on the path that reaches the `elif`. No write can occur in that window, so
`if not existed` observes exactly what `path.is_file()` observed at that point.
The change is a saved stat, not a latent bug. `apply_edit` is the first thing
that can write on the `edit` route and it runs after the guard.

**Lead 3 — `apply_todo` samples after the `keep` early-return: correct and
necessary.** `keep` means "this call says nothing about the list"; a stat is
not a mutation, but hoisting the sample above the early return would make the
function's cheapest path pay for a branch it never reaches, and would put the
sample before the one action defined by touching nothing. The asymmetry against
`apply_task` — which has no `keep`, so its sample is unconditional at the top —
is real and now named in the docstring rather than left for a reader to
rediscover.

**Lead 5 — the phantom-`D` route is fully retired.** Three sites in the repo
emit a `D` line, all in `scripts/checkpoint.py`, and each is now guarded:

| site | guard |
| --- | --- |
| `apply_task` shared removal (350) | `if not existed: return []` immediately above |
| `apply_todo` `clear` (375) | same |
| `apply_todo` tail (387) | `if existed else []` |

`apply_todo`'s `edit` route additionally errors when the file is absent, so it
cannot reach the tail with `existed` false. No path emits a `D` for a file that
was never on disk. Phase 2 may rely on that.

One note for Phase 2, out of scope here and **not** a defect: `write-stage.sh`
is the repo's other `git add -f` on a removal, and it fires only after an agent
Write/Edit, so its target always existed on disk. It is therefore the *other*
route Phase 2 must still guard itself — a file that existed but was never in
the index — exactly as the dispatch anticipated.

## Verification

The tests are OUT of scope and were neither edited nor moved. I ran them, and
ran three in-place mutations of `scripts/checkpoint.py` to confirm they still
discriminate against the **restructured** `apply_task`, since my fix changed
the branch they were written against. Each mutation was applied and reversed by
an exact-string edit (never `git checkout --`, which would have discarded my
own fixes along with the mutation), and after every cycle the fix-only diff was
compared against a SHA-256 recorded before the first mutation — identical all
three times, so no mutation stacked and none survived.

| mutation of the restructured `apply_task` | reds |
| --- | --- |
| removal branch always returns `D` (`unlink(missing_ok=True)`) | `test_task_clear_never_existed_writes_nothing_no_d`, `test_task_write_only_headings_never_existed_no_d`, plus two empty-manifest rows |
| removal branch never returns `D` | `test_task_clear_removes_pre_existing_file_manifest_records_d`, `test_task_write_only_headings_pre_existing_removed_manifest_records_d` |
| `or lib.is_empty_body(content)` dropped from the branch condition | both `test_task_write_only_headings_*` rows |

The first two bracket the `existed` guard from either side, reproducing the
test review's own pair against the new shape. The third is the one the
restructure introduced the risk of: it confirms the empty-body route did not
quietly stop being a removal route when it stopped writing first.

Full gate afterwards:

```
$ just precommit
shellcheck -x .bin/* bin/* scripts/*.sh tests/*.bats
ruff check scripts tests / ruff format --check / docformatter --check
mypy / ty check
bats tests/hook-test.bats tests/checkpoint.bats   1..159
pytest                                            214 passed, 11 deselected
ok
```

`docformatter --check` passing is worth naming: the two rewritten docstrings
are wrapped as it would wrap them, so they will not be reflowed under a later
run.

## Residuals — not fixed, not new

Both were named in the dispatch as already routed by the orchestrator, and I
confirmed neither is affected by my fixes:

- The two slice 1 rows whose absence assertion stands over an empty manifest
  (`test_task_clear_never_existed_writes_nothing_no_d`,
  `test_todo_keep_leaves_pre_existing_list_alone`). Slice 4's own never-existed
  rows do not share the weakness — each carries a second field whose `W` line
  must survive.
- No test asserts that `precompact` *applies* task/todo content.

Nothing was found that needs a module split or a new abstraction; no
UNFIXABLE.
