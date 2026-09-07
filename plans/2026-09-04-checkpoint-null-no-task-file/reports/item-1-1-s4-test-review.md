# Item 1.1 slice 4 — test review

Verdict: **accepted with fixes applied.** The report's four-row classification
reproduces exactly on my own run — the two never-existed rows FAILED on their
manifest assertions, the two pre-existing rows PASSED, and the report does not
lean on the passing pair as evidence of anything.

One finding, fixed:

- **Major** — both never-existed halves stood over an *empty* manifest, so
  their absence assertion was satisfied by "the manifest says nothing about
  anything". Fixed by giving each row a second field whose `W` line must
  survive, and mirroring that payload into the pre-existing half so the pair
  still differs only in the trigger.

One residual, deliberately **not** fixed (slice 1's rows, committed and green;
routing is the orchestrator's call — see the last section).

`git diff --stat scripts/checkpoint.py` was empty when this review began and is
empty now. Every mutation below was applied in place and restored; the restore
was verified by an empty `git diff --stat scripts/checkpoint.py` after each
cycle and again at the end.

## Mechanical first check — the red is genuine, and classified correctly

```
$ pytest tests/test_checkpoint.py -k "test_task_write_only_headings or test_todo_write_no_items" -v
test_task_write_only_headings_pre_existing_removed_manifest_records_d PASSED
test_task_write_only_headings_never_existed_no_d                      FAILED
test_todo_write_no_items_pre_existing_removed_manifest_records_d      PASSED
test_todo_write_no_items_never_existed_no_d                           FAILED
2 failed, 2 passed, 120 deselected
```

Both failures are `AssertionError` on the manifest-content assertion — no
ERROR, no missing symbol, no schema rejection. The failure text names the
phantom directly (`assert 'handoff-task.md' not in 'D .claude/handoff-task.md\n'`).

The report's own classification matches: it labels the two passing rows "the
unchanged contract", explains they carry the original test's assertions against
a corrected fixture, and draws no inference from their being green. That is the
right reading.

**One thing the report understates.** The original
`test_task_write_only_headings_removed_manifest_records_d` did *not* pre-create
the file — so its `D` assertion was an assertion **of the phantom**. Under the
planned GREEN the original row would have gone red. The split is therefore a
correction of a row that encoded the defect, not merely the addition of a
second half; the pre-existing fixture is what makes the surviving assertion
true for the right reason. The report says this parenthetically
("now against a fixture that actually pre-creates the file it claims to be
'pre-existing'"); it is worth stating as the reason the rename was mandatory.

## Lead 1 — does the pair actually pair? Yes, and within the pair

The dispatch's question: an `apply_task` write route returning `[]`
unconditionally passes the never-existed half — what reds it?

Answer: **`test_task_write_only_headings_pre_existing_removed_manifest_records_d`,
inside the pair**, and nothing else in the file. Demonstrated rather than
argued. Applying the planned GREEN to both routes and then mutating the
empty-body branch to `return []` unconditionally:

```
$ pytest tests/test_checkpoint.py -q          # planned GREEN + mutation (a)
FAILED test_task_write_only_headings_pre_existing_removed_manifest_records_d
FAILED test_todo_write_no_items_pre_existing_removed_manifest_records_d
2 failed, 122 passed
```

Exactly the two pre-existing halves, one per route, and no other row in the
124. So the pairing is carried by the pair, not by the surrounding suite — the
stronger of the two readings the dispatch asked me to distinguish.

The complementary mutation is the present HEAD: unconditional `D`, which reds
exactly the two never-existed halves. Between them the two mutations bracket
the branch, and no single-route error survives both:

| wrong implementation | what reds |
| --- | --- |
| `D` unconditional (HEAD) | never-existed half of that route |
| `[]` unconditional | pre-existing half of that route |
| `existed` sampled after the write | never-existed half (existed always true) |
| fix applied to one route only | that route's never-existed half; the rows are per-route |
| stray `W` in place of the `D` | never-existed half — the broad absence catches any line naming the file |

The last row is why the slice 3 note's broad-absence form is right here: a
membership test for one exact `D` line would let a stray `W` through.

Under the planned GREEN with no mutation the **whole file is green** (124
passed), so the planned implementation is sufficient for this slice and
regresses nothing else.

## Lead 2 — the never-existed rows were trivially true (fixed)

Confirmed as the dispatch suspected, and it was the one real weakness. In the
task row `todo` was `todo_keep()` (→ `[]`); in the todo row `task` was
`task_clear()` against a never-existed file (→ `[]`). After the GREEN the
manifest is the empty string in both, so `"handoff-task.md" not in ""` holds
for reasons having nothing to do with the task route. The row's other
assertions do not compensate: `not (…handoff-task.md).exists()` is the one the
slice 1 code review already ruled non-discriminating, and
`checkpoint-manifest.is_file()` is true of a checkpoint that did nothing at
all.

So the row discriminated against today's defect and against nothing else. It
watched an observable the success path never produces — the third staleness in
`green-is-not-evidence` ("check that the observable the negative watches is one
the positive path actually produces").

**Fix applied: carry a second field whose line must survive**, rather than
pinning the manifest's exact emptiness. Emptiness-pinning would have been
equivalent to the present assertion for this fixture (with `todo_keep()` no
other line can appear), so it adds nothing; a surviving line makes the manifest
non-empty on the success path, which turns the absence into a claim about the
route under test.

- `test_task_write_only_headings_never_existed_no_d` — `todo` becomes
  `todo_content("## Remaining\n\n- an item\n")`; asserts
  `"W .claude/handoff-todo.md" in manifest.splitlines()` **then**
  `"handoff-task.md" not in manifest`.
- `test_todo_write_no_items_never_existed_no_d` — `task` becomes
  `task_content("## Current task\n\nreal content\n")`; the mirror assertions.
- Both pre-existing halves take the **same** payload, so each pair still
  differs only in the trigger (prior existence). Their two membership
  assertions are on one bound `…read_text().splitlines()`, matching the
  existing idiom at `tests/test_checkpoint.py:931`.

Neither substring can collide: `W .claude/handoff-todo.md` does not contain
`handoff-task.md`, and vice versa.

The positive is placed **before** the negative deliberately: it is the
precondition that makes the negative mean anything, and a body aborts on the
first failing assert.

That the new positive is not decoration was mutation-checked. With the planned
GREEN applied and the `W` line dropped from both write routes:

```
$ pytest tests/test_checkpoint.py -q -k never_existed   # planned GREEN + mutation (c)
FAILED test_task_write_only_headings_never_existed_no_d
FAILED test_todo_write_no_items_never_existed_no_d
2 failed, 1 passed
```

Both strengthened rows red on the `W` membership. The one that passed is the
residual below.

## Lead 3 — `is_empty_body` really is the trigger

Checked directly against the shared helper rather than inferred:

```
lib.is_empty_body("## Current task\n\n## Open decisions\n")  -> True
lib.is_empty_body("## Remaining\n")                          -> True
lib.is_empty_body("## Current task\n\nstale\n")              -> False
```

Both payload bodies reach the empty-body branch, and the pre-existing fixtures'
bodies are non-empty, so the file the fixture pre-creates is one that would
legitimately be on disk. The empty-body route is what is under test in all four
rows, distinct from the `{"action": "clear"}` route the slice 1 rows above them
cover.

## Lead 4 — the renames

`git grep` for `test_task_write_only_headings_removed_manifest_records_d` and
`test_todo_write_no_items_removed_manifest_records_d` finds **no code
reference**. The hits are all prose in `plans/` — `outline.md`, `runbook.md`,
and the `item-0-1` / `item-1-1-s1-*` / `item-1-1-s4-red` reports. Those are
write-time records naming the rows as they stood when written; per `CLAUDE.md`
they are not revised as the code moves past them, so they are correctly left
alone.

The new names say which half is which without reading the body:
`…_pre_existing_removed_manifest_records_d` and `…_never_existed_no_d`. They
also match the shape slice 1 established one screen above
(`test_task_clear_removes_pre_existing_file_manifest_records_d` /
`test_task_clear_never_existed_writes_nothing_no_d`), so the four
existence-sensitive rows read as one family.

## Residual — the same weakness in two committed slice 1 rows (not fixed)

`test_task_clear_never_existed_writes_nothing_no_d`
(`tests/test_checkpoint.py:612`) and
`test_todo_keep_leaves_pre_existing_list_alone` (:817) both assert a manifest
absence over a manifest that is empty on the success path, for exactly the
reason lead 2 names. Mutation (c) above — which empties the manifest of every
`W` line — leaves `test_task_clear_never_existed_writes_nothing_no_d` **green**,
which is the demonstration.

The `todo_keep` row is the milder case: its load-bearing assertion is
`read_text() == before`, a real positive, and only its manifest negative is
weak. The `task_clear` row has no such positive.

Not fixed here because both are slice 1 rows, committed, green, and outside the
pair this dispatch put under review — amending them would put a slice 1 test
edit inside slice 4's commit. The fix is the same one-line shape applied above:
give the payload a second field whose `W` line must survive, and assert it
before the absence. Flagged for the orchestrator to route (a follow-up item, or
folded into whichever slice next touches those rows).

Also unchanged, and already recorded on the item as a separately scheduled
residual: no test asserts that `precompact` *applies* task/todo content.

## Verification

```
$ pytest tests/test_checkpoint.py -k "test_task_write_only_headings or test_todo_write_no_items" -v
2 failed, 2 passed, 120 deselected            # same two rows, same assertions

$ pytest tests/test_checkpoint.py -q
2 failed, 122 passed                          # red confined to the two never-existed rows

$ ruff check tests/test_checkpoint.py
All checks passed!
$ ruff format --check tests/test_checkpoint.py
1 file already formatted
$ mypy tests/test_checkpoint.py               # exit 0, no output
$ git diff --stat scripts/checkpoint.py       # empty
$ git status --porcelain
 M tests/test_checkpoint.py
?? plans/2026-09-04-checkpoint-null-no-task-file/reports/item-1-1-s4-red.md
```

`just precommit` was not run to completion — the suite is red by design.
No commit made. `scripts/checkpoint.py` is byte-identical to `HEAD`.

**Note on the red report.** `item-1-1-s4-red.md` is left as written. Its quoted
test bodies and its pasted red output predate the lead 2 fix, so the payloads
it shows (`"todo": todo_keep()`, `"task": task_clear()`) no longer match the
file. That is the write-time record behaving as intended — this report carries
the delta.
