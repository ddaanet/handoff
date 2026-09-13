# TDD audit — item 1.1, slice 1

Subject: the TDD execution of the one slice in
`plans/2026-09-08-apply-before-mutate/runbook.md` (Phase 1, item 1.1), audited
from its four dispatch reports plus the phase-1 and phase-2 checkpoints, with
git used only to confirm and diff what a report names.

**Verdict: the slice's evidence is genuine and its discipline held.** The three
negatives red on a failed assertion naming their claim; the two
green-by-design rows were exempted for the reason the runbook gives and each
has a mutation that reds it on a claim it asserts; every recorded mutation
discriminates; every restore is proven and none is live; GREEN edited no test
assertion. Two findings, both about the record rather than the code: the
phase-2 corrector's report says it left a docstring as found that the same
commit fixes (F1), and the one-pass GREEN produced **two** prose defects, not
the one the code review attributed to it (F2) — the second is the audit's most
useful finding and §5 rules on it.

The single-commit/amend convention, the stale shas, the deferred pass-2
minors, the open version bump, `compose_sentinel`'s read-back and the `OSError`
stranding case are excluded by the dispatch and are not treated as findings
anywhere below.

## Method note — the amended intermediates survive

Each amend is still reachable through the reflog, so the dispatch sequence is
recoverable from git after all:

| commit | what it added |
| --- | --- |
| `86d7024` | RED + test-review test edits **and** GREEN's `scripts/checkpoint.py` |
| `867530e` | `item-1-1-s1-green.md` |
| `7608ee4` | code review + its one test-docstring fix |
| `a0a0aae` | `phase-1-corrector.md` |
| `99ce354` | item 2.1's four doc files |
| `1372767` | `item-2-1.md` |
| `532b123` | phase-2 fixes (incl. `scripts/checkpoint.py`) + `phase-2-corrector.md` |

That makes §4's test-integrity check a diff rather than an inference for
everything from GREEN onward. RED, test-review and GREEN share one commit, so
their test edits cannot be separated from each other by git — that half is
judged against the reports, as the dispatch expects.

## 1. RED evidence

**The three negatives red on their own claim.** Each asserts, in the landed
file, `assert task_path.is_file()` ahead of `assert task_path.read_text() ==
task_before`, and the test review records all three failing there with
`AssertionError: assert False` and no pathlib traceback. That is a failed
assertion naming the surviving-task-file claim, not an incidental exception and
not a missing fixture.

**The test review's ruling on the `FileNotFoundError` is correct, and its
supporting evidence is the right kind.** The original red was a genuine SUT
deletion, but its output was byte-for-byte the shape the runbook's own evidence
protocol warns against ("a `FileNotFoundError` from an unwritten fixture prints
as a failure and proves nothing"). A red that cannot be read as evidence from
its own output is not evidence, whatever produced it, so restructuring rather
than annotating was the right call — and the restructure is permanent, not
red-phase scaffolding: a regression that re-introduces the early deletion now
fails on the named claim.

The reviewer's second confirmation is the load-bearing one and I re-derived it:
the old `apply_task` (`4008d31:scripts/checkpoint.py:399-405`) samples `existed
= path.is_file()` and emits `D` only `if existed`, so the positive row's green
`manifest.splitlines() == ["D .claude/handoff-task.md", "W
.claude/handoff-todo.md"]` is the SUT itself reporting that the byte-identical
fixture was on disk when the subprocess ran. That settles "deleted, not
missing" without touching the SUT, which is exactly what was needed.

**The claim is observed a second time, by a different route.** GREEN's mutation
(a) restores the old ordering against the landed code and reds exactly those
three rows on exactly that assertion. The pre-change red and the post-change
mutation are the same claim seen from both sides; either alone would carry it.

**The two green-by-design rows were exempted, not waved through.** The runbook
designates both as characterisation and names the substitute evidence, and both
reports treat them that way explicitly rather than silently. The substitutes
discriminate:

- `..._both_apply_manifest_records_d_and_w` — mutation (c) reds it on its
  exact-two-lines assertion (`['W .claude/handoff-todo.md']` against the
  expected pair); mutation (b) reds its other new claim (`not
  task_path.exists()`).
- `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` — mutation
  (b) reds it on `not (…/handoff-todo.md).exists()`.

Residual, not a finding: the emptying row's `"D .claude/handoff-todo.md" in
manifest.splitlines()` is never the *failing* claim under any recorded mutation
— under (b) the row reds earlier, under (d) its half takes the untouched
`existed == True` branch. The same `_plan_file` line is covered by
`test_todo_clear_removes_pre_existing_file_manifest_records_d`, which does red
under (b) and (c), so the coverage exists; it just is not this row's.

**Process observation worth carrying forward.** The RED phase ran `pytest` but
not the lint half of the gate, so a red `just precommit` would have been
indistinguishable from the three intended failures — the test review's F4. GREEN
and the code review each hit the same `docformatter` gap afterwards. Three
phases in a row is a pattern, not an accident: the RED/GREEN dispatches should
run `docformatter --check` (or the lint half of `just precommit`) before
hand-back.

## 2. The mutation checks as evidence

Seven mutations are on the record. For each I asked the dispatch's question —
could the predicted row's fixture satisfy the guard either way, leaving the
check green under the mutation? — and re-derived the answer against the landed
code rather than the reports.

| # | mutation | predicted red | discriminates? |
| --- | --- | --- | --- |
| (a) | `apply_plan(task_plan)` hoisted above `plan_todo` | 3 negatives | **yes** — each fixture pre-writes a real task file and sends `task_clear()`, so the task plan's `act` is `remove`; the mutation deletes the file the assertion then demands. No fixture satisfies it either way. |
| (b) | `if lib.is_empty_body(body):` → `if False:` | emptying row (+11) | **yes** — the target asserts `not exists()` and the mutation forces the write route. The 11 collateral reds are the same rule reached by `task_clear()`'s empty body; the report names them rather than glossing them. |
| (c) | manifest concatenation reduced to `todo_plan.manifest_lines` | positive (+10) | **yes** — exact list equality against a one-element list. This is also what pins the contract's stated line order. |
| (d) | `_plan_file`'s never-existed branch emits `D` with `act` left `"none"` | 4 never-existed rows (+2) | **yes**, and see below |
| (e) | `keep`'s two-line short-circuit deleted (code review §3) | `test_todo_keep_leaves_pre_existing_list_alone` | **yes** — reds alone, because `keep`'s body is `""` and the resolver reads it as a removal |
| (f) | `write_manifest` made conditional on `manifest_lines` (phase-1 §1) | 4 empty-manifest rows | **yes** — with zero lines the guard suppresses the write and each row reds on `assert manifest.is_file()` |
| (g) | unconditional `write_manifest` inserted ahead of the plan phase (phase-1 §1) | 3 negatives | **yes** — and this is the sharpest check in the slice; see below |

**(d), re-derived.** The mutation touches only `_plan_file:418` (the
`existed == False` removal return). The positive reaches `:419` on its task half
(pre-written file, empty body ⟹ removal with `existed == True`) and `:420` on
its todo half (non-empty edited body ⟹ write); the emptying row reaches `:419`
on both. Neither can observe the mutation. So the code review's claim is
correct **for the stated reason** — the positive is green because of which
branch its fixture takes, not because its assertion is weak. The four rows that
do red are non-vacuous by construction: each asserts a live manifest line
(`"W .claude/handoff-todo.md" in manifest.splitlines()`) before asserting
`"handoff-task.md" not in manifest`, with a comment saying why. A "no D"
assertion that could pass on an empty manifest is the failure mode here, and it
is guarded against explicitly.

**(g) is the check that turned a characterisation claim into evidence.** The
three negatives' `assert not (… / "checkpoint-manifest").exists()` is green
before and after the restructure — the runbook says so, the test review says
so, and neither treats it as red evidence. The phase-1 corrector is the only
pass that asked whether it discriminates at all, and answered it by making the
failure path leave an empty manifest behind: `3 failed, 136 passed`, the three
negatives alone, each on that assertion. Without it, FR7's restated form ("a
wrap-up that fails writes no manifest because it wrote nothing") would rest on
an assertion never shown capable of failing.

**(e), one presentational note.** Its red arrives as a `FileNotFoundError` out
of `read_text()` — the same unreadable shape the test review ruled against in
§1. It is still evidence here, because the row was green immediately before
under code that differs by one authored, immediately-inverted replacement, which
excludes the fixture-never-written reading. But the row would read better with
the same `is_file()` guard its five neighbours now carry.

**Gaps in the set** (recommendations, §7):

1. Nothing pins the guarantee against a *future* apply-time failure.
   `apply_plan`'s "no failure branch" is established by reading, and an `err()`
   added inside it or between the two applies would reopen the defect with no
   row going red. This is the residual the runbook's own rejected-remedy
   argument turns on, and the structural fix narrows it without closing it.
2. FR4's no-stat half is unobservable through a subprocess harness and rests on
   the read. Both the code review and the phase-1 corrector say so plainly,
   which is the right handling.
3. The negatives' todo-bytes-unchanged assertions are green before and after
   and unmutated. `edited_body` errors before returning, so they hold; no
   recorded mutation shows they would red if it stopped doing so.

## 3. The restore protocol

Every mutation was run against committed code, as the runbook requires — GREEN's
four after `86d7024`, the code review's at `867530e`/`86d7024`, the corrector's
two at `7608ee4`.

| report | mutations | mutate in place | invert in the same call | empty diffstat proven | green suite before the next |
| --- | --- | --- | --- | --- | --- |
| GREEN | 4 | yes, `str.replace` count-asserted to 1 | yes | yes, each | yes, `139 passed` each |
| code review | 1 | yes | yes | yes, plus empty `git status --porcelain` | `just precommit` green after; `1 failed, 138 passed` under the mutation |
| phase-1 corrector | 2 | yes | yes | yes, each | **not recorded between the two** |

No report relocates a test, and none stages a backup under `$TMPDIR` — both are
stated negatively where the runbook asks for it.

The one record-keeping gap is the corrector's: it proves each restore with an
empty `git diff --stat scripts/checkpoint.py` and runs `pytest` before the first
mutation and `just precommit` after the second, but records no green suite
between mutation 1's restore and mutation 2. The substance is unaffected — an
empty diffstat against committed code is a byte-level restore proof, strictly
stronger than a green suite, which can pass over a mutation the tests do not
reach. Worth a one-line fix to the report's habit, not to its conclusion.

**End state, verified here:**

```
git status --porcelain            → empty
git diff 532b123 --stat           → empty (repo-wide, not just scripts/)
grep -rn MUTATION scripts/ tests/ → nothing
pytest tests/test_checkpoint.py   → 139 passed
pytest                            → 229 passed, 11 deselected
ruff check / ruff format --check / docformatter --check → clean
```

No mutation is live and no backup artifact survives.

## 4. Test integrity — GREEN edited no assertion

Confirmed from the diff, not inferred. The whole RED+review+GREEN test diff
(`4008d31..86d7024`, `tests/test_checkpoint.py`) contains exactly two things:

- the five slice rows, and
- one line at `:538`, `apply_edit`'s → `edited_body`'s inside the
  `test_task_or_todo_action_vocabulary_errors_naming_field` docstring — the one
  edit the dispatch permitted, in the place it named.

Nothing else in the file is touched. Every change to a pre-existing row's
assertions is a strengthening, never a substitution:

| row | change |
| --- | --- |
| absent | `"old_string"` → `"todo.old_string"`; `"keep this" in …` → bytes equality; **gained** the task-file pair and no-manifest |
| ambiguous | `"old_string"` → `"todo.old_string"`; **gained** a todo-bytes assertion the original lacked, plus the task-file pair and no-manifest |
| missing | **gained** the task-file pair and no-manifest; kept all three originals |
| positive | manifest membership → exact list equality (pins order and the absence of a third line); **gained** `not task_path.exists()` |

Post-GREEN, the only test-file change in the whole amend chain is the code
review's 9-line docstring replacement at `:926` — prose, no assertion. The
dispatch's constraint held.

## 5. The one-pass GREEN — ruling

**The deviation cost nothing in implementation quality, and the safeguard that
caught its consequence was structural for the defect that was found and
accidental for the defect that was not.**

*Why it cost nothing.* The three reds share one root cause, so "one test at a
time" was not available in any meaningful sense — the smallest change that
greens one greens all three. More to the point, the reds never constrained the
implementation's shape at all: hoisting the two `edit` checks ahead of the task
half would have greened all three, and the runbook rejects that remedy by name.
The landed design comes from the `Interfaces:` contract, not from the tests. So
the protection incremental green normally provides — growth bounded by what a
test demands — was inoperative here regardless of how GREEN proceeded, and its
substitute is the code review's conformance check against the `Interfaces:`
block. That check ran (code review §7) and found neither over- nor
under-growth; I spot-verified it against the block and agree — every named
symbol present, no extras, no unread parameter, `apply_plan` with no `else`.

*The consequence, and there were two of them.* The code review names one: a
docstring written in RED against the pre-change code (`apply_todo`'s docstring
names this as the whole reason…) carried into GREEN unrevised, because the pass
was driven by the suite going green rather than by reading each touched
docstring. That one was caught by **structure** — `rg -n
'apply_edit|apply_task|apply_todo'` is mandated by the dispatch and catches, by
construction, every surviving citation of a retired name.

**F2 (finding).** There was a second, and the code review missed it while
reading the very docstring it lives in. `FilePlan`'s docstring landed in GREEN
saying "Its three shapes are produced in one place (`_plan_file`)", which is
false of the code in the same commit: `plan_todo`'s `keep` builds
`FilePlan("none", path, "", [])` directly, and must. The code review's §4
tabulates all four construction sites and calls the fourth "the contract's
deliberate exception" — so it had the fact in hand and did not reconcile it with
the docstring's wording; §5 then signed the same docstring off. The phase-1
checkpoint did not catch it either. It was found two dispatches later by the
phase-2 corrector, while checking a changelog sentence that had been derived
from the same source text, and fixed in the final amend.

That second defect is **not** attributable to the one-pass: its wording is
transcribed verbatim from the runbook's own `Interfaces:` bullet ("Its three
shapes are produced in one place so a plan cannot claim a `D` it will not
perform"), which is internally inconsistent with the same item's instruction two
paragraphs above that `keep` must short-circuit ahead of the resolver. A
one-test-at-a-time GREEN would have copied it just the same.

*The generalizable conclusion.* The pipeline mechanically catches stale prose of
the form "names a symbol that no longer exists". It has no mechanical check for
stale prose of the form "states a rule the code does not obey", and a code
review that reads docstrings for *residue of the old shape* (which §5 did — it
checked that `apply_todo`'s two asymmetries were gone from the prose) is not the
same check as reading each docstring for *the truth of its claim*. Here the gap
was closed only because item 2.1 happened to paraphrase the same sentence into
a changelog the phase-2 corrector checked against the code. Had it paraphrased
differently, the claim would have shipped.

## 6. Coverage of the contract

Judged against the runbook's mapping table. Every requirement is pinned, and
every row that pins one has now been shown to discriminate — but the five slice
rows do not carry the table alone; the named pre-existing rows do a share of it,
which is correct for an item whose subject is a restructure.

| req | pinned by | evidence |
| --- | --- | --- |
| FR2 | the three negatives, on the dotted `todo.old_string` | red on their own claim (§1); the tightening from bare `old_string` is what makes them FR2 assertions rather than assertions about any message mentioning the key |
| FR4 | `test_todo_keep_leaves_pre_existing_list_alone` | mutation (e), reds alone. The no-stat half is unobservable and rests on the read — stated as such by both reviews, which is the honest handling |
| FR5 | the arm-by-arm table in phase-1 §1, plus rows `:643`/`:677`/`:701`/`:723`/`:753`/`:818`/`:1042`/`:890`/`:1145` | I re-derived the two arms where the code shape changed without behaviour changing — `todo: write` (the utf-8 round-trip is identity, so testing `content` before the write equals testing it after) and `write`-to-empty on a never-existed file (old code created then unlinked; new code never creates — same end state, same manifest). The one intended observable delta is the failure path |
| FR6 | the full matrix in phase-1 §1, with the new `edit`-to-empty row filling its only gap | mutation (b), 12 reds including the new row. The one empty cell (`edit` to empty on an absent file) is occupied by the file-missing negative instead, correctly |
| FR7 | (a) order — `:890`, `:1145`; (b) unconditional — the 4 empty-manifest rows; (c) failure writes nothing — the 3 negatives | mutations (c), (f), (g) respectively. All three claims mutation-checked; (b) and (c) only because the phase-1 corrector went looking |
| NFR1 | not a test claim | grep: one pre-existing `subprocess.run` at `:500`, off the plan/apply path; the import diff is `Literal` added to an existing `from typing import`, which the corrector states precisely rather than claiming "no new import" |

The rename's completeness I re-derived independently:
`grep -rn 'apply_edit\|apply_task\|apply_todo'` over `scripts/ tests/ bin/
hooks/ docs/ CLAUDE.md skills/` returns only the new changelog entry (which
describes the retirement) and the frozen 2026-09-07 record. `docs/design.md:240`
was rewired by item 2.1. No alias, no wrapper. I also swept for stale prose that
names no retired symbol (`read.back`, `reads the file`, `wrote first`, `on
disk`) across `checkpoint.py`, `_checkpoint_lib.py` and the test file: every hit
is the sentinel read-back, unrelated. F2's instance is the only one there was,
and it is fixed.

## 7. Findings and recommendations

**F1 (finding, record only).** `reports/phase-2-corrector.md` states, under "Not
fixed, and deliberately", that `FilePlan`'s docstring "makes the same imprecise
claim" and "is left as found and flagged here instead" — but the commit that
carries that report (`1372767..532b123`) *does* change that docstring, to the
corrected two-sentence form. The tree is right and the record is wrong. Two
secondary notes: the edit touches `scripts/`, which that pass declared
scope-OUT and which the phase-1 checkpoint had signed off, with no re-review
recorded; and I verified the change is docstring-only and the gate is still
green (`139`/`229` passed, ruff + docformatter clean), so nothing rides on it.
Recommend a one-line correction to that report.

**F2 (finding).** Two prose defects came out of the one-pass GREEN, not one;
the second (`FilePlan`'s single-producer claim) survived the code review that
read that docstring, survived the phase-1 checkpoint, and was caught only
incidentally. Ruled on in §5.

**Recommendations**, in descending value:

1. Add to the code-review checklist a step distinct from the rename sweep: for
   each docstring in the touched region, name the code line that makes its
   claim true. §5 is the argument; F2 is the instance.
2. Treat a runbook's `Interfaces:` prose as draft, not as text to transcribe.
   The false claim originated there and was inconsistent with the same item's
   own instruction about `keep`.
3. Have the RED and GREEN dispatches run `docformatter --check` (or the lint
   half of `just precommit`) before hand-back. Three consecutive phases hit
   the same gap, and in RED a red gate is indistinguishable from the intended
   red.
4. Give `test_todo_keep_leaves_pre_existing_list_alone` the `assert
   path.is_file()` guard its five neighbours now carry, so mutation (e)'s red
   reads as a failed assertion rather than a `FileNotFoundError`.
5. When a report records consecutive mutations, record the green suite between
   the restores as well as the empty diffstat — the runbook asks for both, and
   the two prove different things.
6. Consider, when the guarantee next moves, a row that would red if an `err()`
   were added inside `apply_plan` or between the two applies. Nothing pins that
   today, and it is the residual the rejected hoisting remedy was rejected for.

None of these is a defect in what landed.
