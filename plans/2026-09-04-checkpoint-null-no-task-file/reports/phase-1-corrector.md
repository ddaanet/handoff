# Phase 1 — checkpoint review

Verdict: **accepted with fixes applied.** The phase delivers what the runbook
specifies. The four mutation matrices carry their weight — I reproduced one
mutation from each of slices 2, 3 and Item 1.2 independently and every one
reproduced, with one count correction. All eight deletions went, none was
inverted, the `main` gate holds for all four skills, and the phantom-`D` route
Phase 2 depends on is fully retired.

One defect found in the code this phase wrote and fixed: `edit`'s two keys
were required but not typed, so a non-string `old_string` exited **1** with a
`TypeError` traceback naming no field. Three documentation corrections applied.

`just precommit` green after the fixes: **159 bats**, **218 pytest passed, 11
deselected** (`tests/test_checkpoint.py` collecting **128** — the phase's 126
plus the two rows below). Working tree carries only these fixes plus this
report. **No commit.**

## Findings

### 1. Major (fixed) — `edit` was the one arm of the union that typed nothing

`validate_todo`'s `edit` arm checked the *presence* of `old_string` and
`new_string` and then `cast("str", …)` both. Every other arm of the union types
its payload (`ttype == "string"` for the content forms, an exact `action`
literal for the object forms), so this was the single unchecked value in the
new schema. Probed rather than reasoned about, against a repo with the todo
file on disk:

```
$ printf '%s' '{…,"todo":{"action":"edit","old_string":5,"new_string":"x"}}' \
    | HANDOFF_ROOT=… python3 scripts/checkpoint.py
TypeError: count() argument 1 must be str, not int
rc=1
```

That is FR2's own contract broken — "a violation exits non-zero **naming the
field**" — and it contradicts slice 3's own heading, "everything outside the
union is a named error". It is pre-existing in the sense that `checkpoint.sh`'s
key-sniffing validator cast the same way, but it is in scope here: the tagged
union is what this item replaced it with, and the union now types every arm but
one.

Note that the *absence* of the guard is not observable from any existing row —
with no todo file on disk the payload errors at `todo.old_string: edit
requested but … does not exist` (exit 2), which is the same shape slice 3's
finding 1 identified as the reason bare-substring reasons go vacuous in this
namespace.

**Fix.** `validate_todo`'s `edit` arm now delegates to `_todo_edit_strings`,
which checks presence *and* type per key, erroring `todo.<key>: must be a
string, got <type>`. Extracted into a helper because inlining the two extra
branches took `validate_todo` to `C901` (12 > 10) and `ruff` refused it — the
helper sits after its only caller, per the repo's entry-points-first
convention.

Two rows added to slice 3's existing table
(`test_task_or_todo_action_vocabulary_errors_naming_field`), each pinning its
own message rather than a bare field name, for the reason that table's own
docstring already gives:

| id | payload | reason asserted |
|---|---|---|
| `todo_edit_old_string_not_a_string` | `{"action": "edit", "old_string": 5, "new_string": "b"}` | `old_string: must be a string, got number` |
| `todo_edit_new_string_not_a_string` | `{"action": "edit", "old_string": "a", "new_string": null}` | `new_string: must be a string, got null` |

**Mutation-checked, not observed passing** (every cycle single, restore
asserted by `sha256sum -c` against a hash taken before the first mutation —
never `git checkout --`, which would have discarded the fix along with the
mutation):

| mutation of `_todo_edit_strings` | reds |
|---|---|
| the type check deleted | the two new rows **alone** (2 failed, 126 passed) |
| the presence check deleted | `todo_edit_missing_{old,new}_string` alone, on the exit code |
| the presence check *weakened* to `todo.setdefault(key, "")` (slice 3's M9w, re-run against the refactor) | the same two rows, now on the **reason** line — slice 3's finding-1 fix survives the extraction |

### 2. Minor (fixed) — `item-1-2-red.md`'s corrected M2 count is one short of what landed

The lead asked me to treat the other reports' quantitative claims with the
suspicion Item 1.2's review earned. One does not hold at `HEAD`. The review
corrected the dispatch's unmeasured disjointness claim to "M1 reds 6, M2 reds
12"; I measured both against the committed tree:

- **M1** (gate narrowed to `if skill == "handoff":`) — reds **6**. Exactly the
  set the correction names: the two `_w[precompact]` rows plus slice 2's four
  `[*-precompact]` rows. Confirmed.
- **M2** (`W` lines dropped from both write routes) — reds **13**, not 12. The
  eleventh extra is `test_task_clear_removes_pre_existing_file_manifest_records_d`,
  which gained a `W .claude/handoff-todo.md` assertion in commit `87ce9c5` when
  the orchestrator closed the pair-symmetry residual **in the same commit the
  review measured before**. The count is right for the tree the review saw and
  one short for the tree that landed.

The property the matrix rests on is untouched — each mutation reds its own
target, no mutation reds every row. Fixed with a dated amendment block in both
`item-1-2-red.md` and `item-1-2-review.md`.

No other report asserts a full-suite property no run in its dispatch measured.
I checked every count in the phase's fourteen reports: the rest are write-time
snapshots of runs that were actually made, correctly scoped to their moment
(107 → 111 → 115 → 122 → 124 → 126), and slice 4's test review explicitly
declines to draw inference from its passing pair.

### 3. Minor (fixed) — two residual records read as open when they are closed

- `item-1-2-review.md` records the pair-symmetry break as "**Residual —
  routed, not fixed**". The orchestrator applied the one-line fix in `87ce9c5`
  instead (the commit message says why: this item is what introduced the
  asymmetry). Confirmed at `tests/test_checkpoint.py` — both halves of the pair
  now carry `todo_content("## Remaining\n\n- an item\n")`. Closure block added.
- The runbook's **"Open residual (recorded 2026-09-07, from slice 2's review)"**
  block under Item 1.1 still reads as open; Item 1.2 below it closes it, but a
  reader meeting the block first has no way to know. Marked closed, with the
  commit.

Also added to the runbook: a note recording the third residual's closure in the
same commit, and a list-revision block for finding 1, in the form the phase's
other revisions use.

**Nothing routed anywhere in Phase 1 is still open and unrouted.** The three
residuals the Item 1.1 reviews raised are all closed — two by Item 1.2, the
third in Item 1.2's commit — and Item 1.2's own review routed nothing forward
except that third one.

## The leads, answered

### Lead 1 — do the mutation matrices carry the weight?

Yes. Method for every cycle: a scripted patcher asserting `count(old) == 1`
before replacing (so a mutation that fails to apply is an error, not a silent
green), one mutation at a time, `git checkout -- scripts/checkpoint.py` for the
restore, and `sha256sum -c` against a hash taken before the first mutation
asserted **in the shell** after every cycle. Tests never relocated. My first
attempt at a baseline hash hit exactly the hazard the runbook names — `$TMPDIR`
is empty in this session's shell, so `sha256sum > "$TMPDIR/base.sha"` was
`Permission denied` on `/base.sha`; the `&&` chain short-circuited and no
mutation ran. Redone under `/tmp/claude/p1review/`.

| source | mutation reproduced | result |
|---|---|---|
| slice 2, A | `null` accepted as an empty write in both validators | **4 red** — `{task,todo}_null` at **both** boundaries; all four `absent` rows green. The A/B disjointness the slice rests on holds. |
| slice 3, M9w | `old_string` guard *weakened* (`setdefault`) rather than deleted | **1 red** — `todo_edit_missing_old_string` alone, on the reason assertion, with the stderr showing the downstream `does not exist` message. This is the row slice 3's finding 1 rescued; the fix works. |
| Item 1.2, M1 | `main`'s gate narrowed to `if skill == "handoff":` | **6 red**, exactly as corrected. The two `_w[precompact]` reds are `assert (…).is_file()` — a failed assertion, not a payload rejection. |
| Item 1.2, M2 | `W` lines dropped from both write routes | **13 red** — see finding 2. |

Every restore verified; `git diff --stat scripts/checkpoint.py` was empty
between every cycle and the file is byte-identical to `HEAD` where my own fix
does not touch it.

### Lead 2 — the deletions

All eight rows are gone and none was inverted. `grep -rn file_path` over
`scripts/checkpoint.py`, `tests/test_checkpoint.py`, `tests/checkpoint.bats`
and `pyproject.toml` returns **zero hits** — there is no absence-guard left
defending a form the schema can no longer express, which is what an inversion
would have produced.

- The four `{"content": null}` no-op rows, the two `file_path`-outside-root
  rows, `test_todo_content_and_old_string_together_errors` and
  `test_drifted_cwd_task_path_under_cwd_rejected`: **absent**.
- The three restated rows are present in slice 3's table as
  `task_edit_rejected` / `todo_edit_missing_new_string` /
  `todo_edit_missing_old_string`, each asserting strictly more than the row it
  replaced (field **and** message).
- The transient `[[tool.mypy.overrides]]` block is gone from `pyproject.toml`,
  and `mypy` is clean without it.
- `test_drifted_cwd_writes_injected_root_never_cwd` is green **and still
  discriminating**: mutating `validate_root` to fall back to `Path.cwd()` reds
  it (plus `test_handoff_root_names_non_directory_refuses`), on
  `(launch/.claude/handoff-task.md).is_file()`. With `file_path` gone this is
  the only coverage that the root comes from `HANDOFF_ROOT`, so I checked it
  rather than trusting the runbook's claim.

### Lead 3 — `main`'s boundary gate

Holds for all four skills. `validate_task`/`validate_todo`/`apply_task`/
`apply_todo` are inside `if skill in ("handoff", "precompact")`;
`write_manifest(root, manifest_lines)` is outside it and unconditional, so the
`autoname`/`restart` rows still get the empty manifest `bash-post.sh`'s
presence-gate needs (`test_{autoname,restart}_manifest_present_empty_neither_file_touched`,
both green). `task`/`todo` remain in both forbidden-field lists, so carrying
either to a non-boundary skill is still a named error rather than a silent
ignore. Mutation M1 above is the evidence the gate is load-bearing in both
directions.

### Lead 4 — the phantom `D` is fully retired

Three sites in the whole repo emit a `D` line, all in `scripts/checkpoint.py`,
each guarded by an existence sample taken before any write:

| site | guard |
|---|---|
| `apply_task:350` (shared removal) | `if not existed: return []` immediately above; `existed` sampled at the top |
| `apply_todo:375` (`clear`) | same |
| `apply_todo:387` (tail) | `return […] if existed else []`; the `edit` route cannot reach it with `existed` false, since it errors first |

No path emits a `D` for a file that was not on disk. Phase 2 may rely on it.
(Phase 2 still has to guard the other route itself — `write-stage.sh`'s
`git add -f` on a file that existed but was never in the index — as slice 4's
code review already noted.)

### Lead 5 — the `apply_task` / `apply_todo` asymmetry

Correct, and both docstrings now describe what the code does. `apply_task`
tests `is_empty_body(content)` — the argument — so with `existed` sampled first
the write on the empty-body path was provably dead and the collapse to one
unlink-if-present is sound. `apply_todo` cannot do the same: its emptiness test
is `is_empty_body(path.read_text(...))`, and on the `edit` route the result
exists only on disk, so the read-back is load-bearing and the tail is genuinely
shared between `write` and `edit`. Skipping the `write` route's write there
would need a second predicate beside the tail's — a duplicated rule in place of
one redundant write. The `apply_todo` docstring names both asymmetries (`keep`
must not even stat the file; the emptiness test reads the file) rather than
leaving a reader to rediscover them.

## Observations — recorded, not fixed

**An action object's extra keys are silently ignored.**
`{"action": "clear", "content": "## Current task\n\nreal\n"}` exits 0 and
writes nothing; the union dispatches on `action` and never looks at the rest.
This is in mild tension with the phase's own premise — that a wrong spelling
must fail loudly rather than acquire a meaning — but rejecting unknown keys is
a **new** schema rule, not a defect against the one the runbook specifies, and
the plausible agent typo (`{"content": …}` with no `action`) is already a named
error. Routed as a question for Phase 3/4, where the two SKILL.md bodies and
`docs/design.md` state the payload contract: if the answer is "extra keys are
an error", that is where it gets written down first.

**`test_todo_edit_requested_file_missing_errors` asserts no field name at all**
(only `"does not exist" in stderr`). Pre-existing, and the runbook explicitly
says these three rows keep their assertions unchanged. Slice 3's review already
recorded it. Not touched.

## Out of scope, confirmed untouched

`.claude/handoff-task.md`, `.claude/handoff-todo.md`, `scripts/bash-post.sh`
(Phase 2), both `SKILL.md` bodies (Phase 3 — still documenting the retired
`file_path` + `content` shape, which is the scheduled inconsistency, not a
finding), `docs/`, `CLAUDE.md` (Phase 4).

## Verification

```
$ just precommit
jq . .claude-plugin/plugin.json / hooks/hooks.json / .claude/settings.json   ok
shellcheck -x .bin/* bin/* scripts/*.sh tests/*.bats                        ok
ruff check scripts tests                                                    ok
ruff format --check scripts tests                                           ok
docformatter --check scripts/*.py tests/*.py                                ok
mypy                                                                        ok
ty check                                                                    ok
bats tests/hook-test.bats tests/checkpoint.bats             1..159, all ok
pytest                                      218 passed, 11 deselected
$ pytest tests/test_checkpoint.py --collect-only -q         128 tests collected
$ git status --short
 M plans/2026-09-04-checkpoint-null-no-task-file/reports/item-1-2-red.md
 M plans/2026-09-04-checkpoint-null-no-task-file/reports/item-1-2-review.md
 M plans/2026-09-04-checkpoint-null-no-task-file/runbook.md
 M scripts/checkpoint.py
 M tests/test_checkpoint.py
```

218 = the phase's 216 plus the two new rows. No UNFIXABLE. **No commit made.**
