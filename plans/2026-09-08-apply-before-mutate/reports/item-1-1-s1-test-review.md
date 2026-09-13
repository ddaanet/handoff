# Item 1.1, slice 1 — test review

Scope reviewed: the five `test_todo_edit_*` rows in `tests/test_checkpoint.py`
and `plans/2026-09-08-apply-before-mutate/reports/item-1-1-s1-red.md`.

Verdict: **the slice's tests are sound after four fixes, all applied here.**
The three negatives red on a failed assertion naming the claim; the two
characterisation rows are green, correctly.

## SUT unchanged

```
$ git diff --stat scripts/checkpoint.py
$
```

Empty diffstat — `scripts/checkpoint.py` is byte-for-byte unchanged through
this review. Working tree after the review:

```
$ git status --porcelain
 M tests/test_checkpoint.py
?? plans/2026-09-08-apply-before-mutate/reports/item-1-1-s1-red.md
?? plans/2026-09-08-apply-before-mutate/reports/item-1-1-s1-test-review.md
```

No commit made.

## The ruling: the red must be a failed assertion, not a raised exception

**Finding.** All three negatives ended their run with

```
E       FileNotFoundError: [Errno 2] No such file or directory: '.../repo/.claude/handoff-task.md'
```

raised eight frames deep inside `pathlib` by `Path.read_text()` on the line
`assert (repo / ".claude" / "handoff-task.md").read_text() == task_before`.

**First: the fixture really is written before the subprocess.** Two
independent confirmations, neither of which touches the SUT:

1. Source order. In each of the three bodies the write statement
   (`task_path.write_text(task_before)`) precedes `run_checkpoint(repo,
   payload)` with nothing between them but the payload literal.
2. Green-test evidence, which is the stronger half. The positive row
   `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` builds
   the task half with a byte-identical fixture at the identical point in its
   body, and asserts the manifest's lines are exactly `["D
   .claude/handoff-task.md", "W .claude/handoff-todo.md"]` — and it passes.
   `apply_task` (`scripts/checkpoint.py:399-405`) samples `existed =
   path.is_file()` *before* acting and emits a `D` line only `if existed`. So
   the `D` in that green row is the SUT itself reporting that the fixture was
   on disk when the subprocess ran.

   The three negatives cannot use that route to prove it — no manifest is
   written on the error path, which is the point of their own no-manifest
   assertion — so the positive is where the evidence lives.

The exception was therefore genuinely the SUT's deletion, as the RED report
claimed. But that was not readable from the report's own output.

**Ruling: restructure.** Applied — each negative now binds `task_path` and
asserts existence ahead of the bytes comparison:

```python
    assert task_path.is_file()
    assert task_path.read_text() == task_before
```

Reasons, in order of weight:

- A `FileNotFoundError` out of `read_text()` is *indistinguishable in the
  output* from the failure mode the slice's own evidence protocol warns
  against — a fixture that was never written. Both print the same exception
  from the same frame. The red therefore could not be read as evidence without
  going outside it, which is exactly what `genuine-red-not-missing-sut` rules
  out: the red has to be a failed assertion, and the assertion has to name the
  claim.
- The restructure is not a red-phase convenience that the GREEN dispatch
  discards. It is permanent: once the implementation lands, a regression that
  re-introduces the early deletion fails on `assert task_path.is_file()` naming
  the surviving-task-file claim, rather than on an incidental raise. The bytes
  comparison stays as the second, stricter claim — "present" and "unmodified"
  are two claims and both are wanted.
- It costs one line per row and no expressiveness.

Post-fix red, verbatim (`pytest tests/test_checkpoint.py -k
"absent_errors_task_file_survives"`):

```
__________ test_todo_edit_old_string_absent_errors_task_file_survives __________

        result = run_checkpoint(repo, payload)
        assert result.returncode == 2
        assert "todo.old_string" in result.stderr
        assert "not found" in result.stderr
        assert (repo / ".claude" / "handoff-todo.md").read_text() == todo_before
>       assert task_path.is_file()
E       AssertionError: assert False
E        +  where False = is_file()
E        +    where is_file = PosixPath('.../repo/.claude/handoff-task.md').is_file

tests/test_checkpoint.py:978: AssertionError
```

The other two negatives fail identically, at `tests/test_checkpoint.py:1006`
and `:1031` respectively, each on `assert task_path.is_file()` with the same
`AssertionError: assert False`. No pathlib traceback, no exception: the red now
reads as the claim the row's name states.

## Other fixes applied

**F2 — the stderr assertions did not pin the field.** The absent and ambiguous
rows asserted `"old_string" in result.stderr`, not `"todo.old_string"`. The
slice text requires the dotted name on all three, and FR2's contract is that
the error *names the offending field*. The bare substring is satisfied by any
message mentioning `old_string` — including `_todo_edit_strings`'s own
`todo.old_string: required for …` / `must be a string, got …`, which are
different errors reached on a different branch. Tightened both to
`"todo.old_string"`. The third row already did this.

**F3 — the absent row's todo claim was a substring, not the bytes.** It
asserted `"keep this" in (…).read_text()`, which stays true if the edit
appended, prefixed or reordered around that item. The slice specifies "the todo
file's bytes unchanged". Bound `todo_before` and asserted equality, matching
the ambiguous row's shape. This is a strict superset of the original claim.

**F4 — the two new docstrings failed `docformatter`, which gates
`just precommit`.** `docformatter --check scripts/*.py tests/*.py` exited 3 on
`tests/test_checkpoint.py` with the change applied and 0 against `HEAD`, so the
RED phase introduced it: a multi-sentence summary that docformatter splits into
a summary line plus a body paragraph. Ran `docformatter --in-place`; the
docstrings' content is unchanged, only their line layout. This one is worth
naming for the process rather than the diff — the RED phase ran `pytest` but
not the lint half of the gate, so a red `just precommit` would have been
indistinguishable from the three intended failures.

Post-fix lint, all green: `ruff check`, `ruff format --check`,
`docformatter --check scripts/*.py tests/*.py`, `mypy`, `ty check`.

## Wrong-reason hunting — the criteria the dispatch named

**Do the five rows differ only in the trigger?** Yes. All five payloads are
identical field for field — `"skill": "handoff"`, `"commit": "with-commit"`,
`"rename": "T"`, `"clear": False`, `"continue": None`, `"task": task_clear()` —
except `todo`, which carries the `edit` whose `old_string` match count is the
trigger: zero (absent), two (ambiguous), no file at all (missing), one
(positive), one-that-empties-the-list (the new row). The todo *fixture* differs
alongside, which is what the trigger is made of and what the slice specifies.

**Is the task half genuinely shared and identical?** Yes — all five now open
with the same three lines binding `task_path`, `task_before = "## Current
task\n\nrecognisable\n"` and the write. I considered hoisting that literal into
a shared helper so the identity is structural rather than by convention, and
rejected it: the file's own idiom is an inline literal bound to a local named
`before`/`todo_before` (e.g. `test_todo_keep_leaves_pre_existing_list_alone`),
tests favour an explicit fixture over DRY, and a shared helper would invite
reuse by rows outside the five, at which point "the fixture the five share"
stops being a property anyone can check by reading them. Binding `task_path` in
all five — including the two rows that only write it — is what I did instead:
it makes the shared fixture visually identical across the block.

**Does the positive pin the manifest's order?** Yes —
`manifest.splitlines() == ["D .claude/handoff-task.md", "W
.claude/handoff-todo.md"]` is a list equality, so task-line-first is pinned,
and so is the absence of any third line.

**Does the new row assert membership?** Yes — `"D .claude/handoff-todo.md" in
manifest.splitlines()`, membership against the split lines rather than a raw
substring of the file. Correct for the reason the slice gives: this row's
manifest also carries the task's own `D`, so exact-lines would be asserting the
positive's claim a second time.

**Do the renamed rows keep every claim their originals made?** Yes, confirmed
against `git diff`. Nothing was substituted:

- absent — kept returncode 2, `old_string` (now tightened), `not found`, and
  the todo-file claim (`"keep this" in …`, now strengthened to bytes
  equality); gained the task-file pair and no-manifest.
- ambiguous — kept returncode 2, `old_string` (tightened), `ambiguous`;
  **gained** a todo-bytes-unchanged assertion the original did not have,
  plus the task-file pair and no-manifest. An addition, not a substitution.
- missing — kept returncode 2, `todo.old_string`, `does not exist`; gained
  the task-file pair and no-manifest.
- positive — kept returncode 0, `finish A` gone / `finish B` present, and the
  `W .claude/handoff-todo.md` manifest line (now inside an exact-lines
  assertion that also pins the task `D` and the order).

**Is the pairing real?** Yes, and it is the shape `green-is-not-evidence`
prescribes: three negatives and one positive over one fixture, differing only
in the guard's trigger input. The negatives' task-file claim is discriminating
— it fails today and will pass only once the plan/apply split lands — and the
positive proves the same fixture *is* deletable on the success path, so the
negatives are not passing because the file was never a candidate for deletion.

**Could the no-manifest assertion go vacuous?** It is green before and after,
as the slice says, and it sits behind the task-file claim in each body, so it
is not what produces the red. It is a real observable (FR7: a wrap-up that
fails writes nothing, so it writes no manifest) and a fair characterisation
claim.

**Name re-derivation.** Re-derived mechanically rather than trusting the
runbook's enumeration: grepped all six names (four old, two new) repo-wide.
Live hits are `tests/test_checkpoint.py` only; everything else is under
`plans/`, which is frozen write-time record. Nothing in `CLAUDE.md`, `docs/`,
`scripts/`, `skills/` or `tests/*.bats` cites any of them. The runbook's and the
RED report's claim holds.

## Not applied, and why

- **The missing-file row does not assert the todo file is still absent.** The
  slice enumerates that row's assertions exactly and does not call for it, and
  the row's subject is the *task* file's survival. Noting it as an observation
  rather than adding an assertion the slice did not specify. It is not a
  wrong-reason risk: nothing about the row can pass for a reason other than the
  one it names.
- **The RED report's own red output was not rewritten.** It records what the
  run produced at the time, and rewriting it to show output it never produced
  would fabricate history. A dated pointer to this report was appended to it
  instead, so a later reader is not misled about what is on disk now.

## Report accuracy — `item-1-1-s1-red.md`

Its evidence is what it claims, with one wording defect:

- The `FileNotFoundError` blocks, the failing line, and the "preceding
  assertions all passed" notes match what I reproduced before fixing. The
  report is honest that the red was a raise rather than a failed comparison —
  it states the exception verbatim rather than paraphrasing it as an assertion
  failure. It is the *structure* that was wrong, not the reporting.
- "not the no-manifest assertion (that one is never reached in either version)"
  — "either version" is wrong looking forward: after the restructure lands, the
  negatives run to completion and that assertion is reached. What the sentence
  means is true of the pre-GREEN code only. Corrected in the appended note.
- Its "3 failed, 136 passed" full-suite line still holds post-fix: same three
  failures, same counts.

## Post-fix verification

```
$ pytest tests/test_checkpoint.py -q
3 failed, 136 passed in 24.64s
FAILED tests/test_checkpoint.py::test_todo_edit_old_string_absent_errors_task_file_survives
FAILED tests/test_checkpoint.py::test_todo_edit_old_string_ambiguous_errors_task_file_survives
FAILED tests/test_checkpoint.py::test_todo_edit_requested_file_missing_errors_task_file_survives
```

```
$ pytest tests/test_checkpoint.py -v -k "both_apply_manifest_records_d_and_w or emptying_the_list"
tests/test_checkpoint.py::test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w PASSED
tests/test_checkpoint.py::test_todo_edit_emptying_the_list_removes_it_manifest_records_d PASSED
2 passed, 137 deselected in 0.56s
```

Three negatives red on `assert task_path.is_file()` — the intended claim, as a
failed assertion. Two characterisation rows green, as designed. Nothing else in
the file regressed. No UNFIXABLE items.
