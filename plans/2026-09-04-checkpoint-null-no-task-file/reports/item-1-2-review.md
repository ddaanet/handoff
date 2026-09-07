# Item 1.2 — test review

Verdict: **accepted with fixes applied.** Both residuals are genuinely closed —
each amended row is red under the mutation the runbook named and green without
it, and the before-half (unamended rows, same mutation, green) reproduces, so
the amendment is what changed the outcome rather than decoration on something
already sound. No row is un-reddable.

Three fixes applied: one to `tests/test_checkpoint.py`, two to the dispatch
report `item-1-2-red.md`, whose two quantitative claims about the matrix do not
reproduce.

`git diff --stat scripts/checkpoint.py` was empty when this review began, after
every one of the four mutate→run→restore cycles below, and is empty now. Every
restore was `git checkout -- scripts/checkpoint.py` followed by both an empty
`git diff --stat` **and** a `diff -q` against a byte copy taken before the first
mutation — never a `cp` restore. No mutation was ever stacked on another.

## Method note — how the before-half was reconstructed

`git checkout -- tests/test_checkpoint.py` is refused by this session's
permission gate (it would destroy the working-tree amendments), so the
unamended rows were reconstructed as `git show HEAD:tests/test_checkpoint.py`
written to `tests/unamended_checkpoint_check.py` — **inside `tests/`**, so
`REPO_ROOT = Path(__file__).resolve().parent.parent` still resolves, and under
a name pytest does not auto-collect. The amended file was never touched during
a before-run (verified by sha256 against a copy taken at the start). The
temporary file was deleted before the final gate; `git status --short` shows
only `tests/test_checkpoint.py` modified.

## Independent reproduction of the mutation matrix

Reconstructed from the report's descriptions, not copied from its commands.

| | Mutation, as re-derived | Before (HEAD rows) | After (amended rows) |
|---|---|---|---|
| M1 | `scripts/checkpoint.py:487`, `if skill in ("handoff", "precompact"):` → `if skill == "handoff":` | **2 passed** — green, the defect | **2 failed, 2 passed** — exactly the two `precompact` halves |
| M2 | `:352` `return [f"W {HANDOFF_REL_TASK}"]` → `return []`; `:388` `return [f"W {HANDOFF_REL_TODO}"]` → `return []` | **2 passed** — green, the defect | **2 failed** — both on `assert "W ..." in manifest.splitlines()` |

Both halves of both mutations reproduce exactly as claimed for the four target
rows. The before-halves are the load-bearing evidence and they hold: at `HEAD`
the rows are green under the very mutation that reds them after.

**M1 reds for the right reason** — the dispatch's lead 2. In both `precompact`
halves the preceding `assert result.returncode == 0` **passes**, so the red is
not a malformed payload exiting non-zero; the failure is the file not being
written:

```
        assert result.returncode == 0
>       assert (repo / ".claude" / "handoff-task.md").is_file()
E       AssertionError: assert False
```

Two further mutations, not in the report, to check that the amendment did not
weaken either row's *original* claim (dispatch lead 3):

| | Mutation | Result |
|---|---|---|
| M3 | `apply_todo`'s `keep` branch writes `"clobbered\n"` before returning `[]` | `test_todo_keep_leaves_pre_existing_list_alone` **red** on `read_text() == before` — FR4's keep guarantee is still pinned |
| M4 | `apply_task`'s removal branch emits `D` unconditionally (`if not existed:` → `if False:`, `unlink(missing_ok=True)`) | `test_task_clear_never_existed_writes_nothing_no_d` **red** on `assert "handoff-task.md" not in manifest` — the row's own claim survives the added `todo` field |

So each of the four rows carries two independent claims, and each claim has a
mutation that reds it alone.

## Finding 1 (Minor, fixed) — `test_todo_write_creates_file_manifest_records_w` red as an exception, not an assertion

Under M1 the `precompact` half failed with

```
E  FileNotFoundError: [Errno 2] No such file or directory: '.../handoff-todo.md'
```

raised from `read_text()`, because unlike its task twin the row had no
existence assertion before reading. `genuine-red-not-missing-sut` wants a red
that is a **failed assertion** naming what is wrong; an exception out of a
fixture read is the shape that memory exists to keep out of the evidence
record, and it makes "the file was not written" and "the read blew up for some
other reason" look alike at a glance.

Fixed by mirroring the task row's own line:

```python
    assert (repo / ".claude" / "handoff-todo.md").is_file()
    assert (repo / ".claude" / "handoff-todo.md").read_text() == content
```

Re-ran M1 against the fixed row — the red is now
`AssertionError: assert False … is_file` on the `[precompact]` id, with
`[handoff]` still green, and `scripts/checkpoint.py` restored and verified
after.

This was pre-existing (the unparametrized row read the file the same way), but
it is one of the four rows this item owns and it is precisely this item's
evidence path, so it is in scope.

## Finding 2 (Major, fixed in the report) — the disjointness claim does not reproduce

`item-1-2-red.md` stated:

> Neither mutation reddens a row outside its own target — M1's red set is
> exactly `{task_write[precompact], todo_write[precompact]}`; M2's red set is
> exactly `{task_clear_never_existed, todo_keep_leaves_pre_existing}`.

That is a full-suite property, and no run in the dispatch established it — every
pasted run is `-k`-filtered to the target rows. Run against the whole amended
file it is false:

- **M1 reds 6**, not 2. The extra four are
  `test_task_or_todo_null_or_absent_errors_naming_field[*-precompact]` — slice
  2's table, which covers the *validation* half of the same `main` gate.
- **M2 reds 12**, not 2. The extra ten are every other row asserting a `W`
  line: both `_w` rows at both boundaries, slice 4's four
  `_pre_existing_`/`_never_existed_` rows,
  `test_todo_edit_replaces_first_occurrence_stages_w`, and
  `test_task_and_todo_both_written_manifest_lists_both`.

Neither excess is a defect in the tests — the extra reds are correct coverage,
and M1's in particular are the direct confirmation that residual 1 really is
"the half slice 2 left open". The defect is in the record: a stated fact that a
later auditor re-running the matrix will find false, with no way to tell whether
the tests or the report moved. What the matrix actually needs is weaker and does
hold — each mutation reds its own target, no mutation reds every row, and the
before/after pairing is per-target.

Fixed in `item-1-2-red.md` with a dated `> **Corrected at review**` block under
the paragraph, carrying the measured red sets, plus a pointer from each table
cell. The paragraph itself was rewritten to claim only disjointness *of what
each mutation edits*, which is true.

## Finding 3 (Minor, fixed in the report) — count arithmetic

The report read "**126 passed** (122 existing + 4 new rows from the two
now-parametrized tests gaining a `precompact` case each)". Both numbers are
wrong: `git show HEAD:tests/test_checkpoint.py` collects **124**, and two tests
each gaining one case is **+2**. 124 + 2 = 126 — which the report's own pasted
deselect counts already imply (`6 passed, 120 deselected`). Corrected in place
with the same dated block.

**No row was silently lost.** `diff` of the `^def test_` name lists between
`HEAD` and the amended file is empty, so the whole 124 → 126 delta is
parametrization.

## Lead 1 — the fixture's own branch

`if skill == "handoff": rename/clear … else: compact` is correct against the
schema, checked in `scripts/checkpoint.py` rather than against the report:
`validate_rename` requires `rename` for `handoff` and forbids it for
`precompact`; `_build_handoff_transition` requires `clear` and forbids
`compact`; `_build_precompact_transition` is the exact mirror. `commit` and
`continue` are required at both boundaries, so they correctly stay in the shared
literal. The two envelopes therefore differ only where the schema forces them
to.

It is byte-for-byte the shape slice 2's committed
`test_task_or_todo_null_or_absent_errors_naming_field` already uses, which is
the right call: an untested branch inside a fixture is a hiding place, and
having one shape in the file rather than two is what keeps it readable. The
`else:` would silently build a `precompact` envelope if a third skill were ever
added to the parametrize list, but that is equally true of slice 2's row and
diverging here would be worse than sharing the flaw.

## Lead 4 — same shape as slice 4's fix

Both fixes are recognisably slice 4's lead-2 fix: a second field whose `W` line
must survive, asserted *before* the absence, with a comment saying why. The
substring pairs cannot collide (`W .claude/handoff-todo.md` does not contain
`handoff-task.md`, and vice versa), and the positive-before-negative ordering is
preserved in both.

One divergence, recorded below rather than fixed.

## Residual — routed, not fixed

**The `task_clear` pair no longer differs only in its trigger.** Slice 4's
review made a point of mirroring the new payload into *both* halves of its pair
so that "each pair still differs only in the trigger (prior existence)". This
item changed `test_task_clear_never_existed_writes_nothing_no_d` to carry
`todo_content(…)` but left its partner
`test_task_clear_removes_pre_existing_file_manifest_records_d`
(`tests/test_checkpoint.py:601`) on `todo_keep()`, so the pair now differs in
two dimensions.

It is presentational rather than a correctness hole — `apply_task` and
`apply_todo` are independent and the pre-existing half's assertion is a positive
`D` membership, which is already strong — but a reader now has to establish that
the todo difference is inert to the task route before trusting the pair.

Not fixed: `test_task_clear_removes_pre_existing_file_manifest_records_d` is a
committed slice 1 row and the dispatch's scope is explicit that every row
outside the four is out ("record it as a routed residual rather than fixing
it"). The fix is one line — `"todo": todo_content("## Remaining\n\n- an
item\n")` in the pre-existing half — for whichever slice next touches those
rows.

No other instance of the defect class survives in this file: the only
manifest-absence assertions are at lines 644, 688, 760 and 861, and all four now
assert a surviving `W` line first.

## Verification

```
$ pytest tests/test_checkpoint.py --collect-only -q      # 126 tests collected
$ just precommit
jq . .claude-plugin/plugin.json / hooks/hooks.json / .claude/settings.json   ok
shellcheck -x .bin/* bin/* scripts/*.sh tests/*.bats                        ok
ruff check scripts tests                                                    ok
ruff format --check scripts tests                                           ok
docformatter --check scripts/*.py tests/*.py                                ok
mypy                                                                        ok
ty check                                                                    ok
bats tests/hook-test.bats tests/checkpoint.bats            1..159, all ok
pytest                                     216 passed, 11 deselected (live)
```

**bats: 159. pytest: 216 passed, 11 deselected** (`tests/test_checkpoint.py`
contributing 126).

```
$ git status --short
 M tests/test_checkpoint.py
?? plans/2026-09-04-checkpoint-null-no-task-file/reports/item-1-2-red.md
$ git diff --stat scripts/checkpoint.py     # empty
```

`scripts/checkpoint.py` is byte-identical to `HEAD`. The report edits are to an
untracked file, so they do not appear separately. **No commit made.**
