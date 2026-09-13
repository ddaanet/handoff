# Deliverable Review: 2026-09-08-apply-before-mutate

**Date:** 2026-09-13
**Methodology:** `docs/design.md` §6.8 "Deliverable review" (edify)
**Range:** `b77a943..HEAD` — one production commit, `53aac3a`, amended per item
2.1's own instruction. `5602338` above it is the handoff snapshot.
**Design baseline:** `plans/2026-09-08-apply-before-mutate/outline.md` (the
plan's design artifact — this job has no `design.md`), with
`classification.md` and `runbook.md` as the scope contract.

## Inventory

| Type | File | +/− |
|---|---|---|
| Code | `scripts/checkpoint.py` | +76 / −51 |
| Test | `tests/test_checkpoint.py` | +88 / −15 |
| Human docs | `docs/changelog/2026-09-13-nothing-is-written-until-both-halves-resolve.md` | +81 / −0 |
| Human docs | `docs/changelog.md` | +1 / −0 |
| Human docs | `docs/design.md` | +7 / −3 |
| Agentic prose | `CLAUDE.md` | +28 / −16 |

281 added / 85 removed — under the 500-line gate, so **Layer 1 was skipped**
and Layer 2 covered both the per-file axes and the cross-cutting checks.

**Design conformance:** every IN-scope file in the outline was produced and no
OUT-of-scope file was touched. `validate_task`/`validate_todo`, the union
vocabulary and its messages, `scripts/bash-post.sh`, the manifest format, the
sentinel composer, `scripts/_checkpoint_lib.py` and both `SKILL.md` bodies are
byte-identical across the range (verified by `git diff --numstat` and by grep
for the retired names). `docs/changelog/2026-09-07-the-payload-names-its-actions.md`
is untouched, including its `apply_task`/`apply_todo` citation at `:53` — correct,
it is a frozen write-time record.

Every interface the runbook names exists with the signature it names, field
order included. No unspecified deliverable.

### Independent verification

`just precommit` green (164 bats rows, 229 pytest, 11 `live` deselected).
`tests/test_checkpoint.py` collects **139**, matching the count the landed
`CLAUDE.md:810` now claims.

The reports record mutation checks; this review re-ran them against the
committed tree rather than reading them, restoring by `git checkout --` and
confirming a clean `git status --porcelain` after each:

| Mutation | Result |
|---|---|
| `apply_plan(task_plan)` hoisted above the `plan_todo` call | exactly the three `…_task_file_survives` rows red, nothing else — the ordering guarantee is pinned |
| `_plan_file`'s `if lib.is_empty_body(body)` → `if False` | 12 rows red, **including** `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` — the new characterisation row is not vacuous |
| `_plan_file`'s never-existed guard emits `D` anyway | 6 rows red — the runbook predicted 4; `test_rename_only_manifest_present_empty_sentinel_written` and `test_precompact_nothing_touched_manifest_still_written_empty` also carry the claim. The positive stays green, as the runbook required |
| manifest concatenation order swapped | 2 rows red, including `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` — its exact-two-lines assertion pins the order |
| `plan_todo`'s `keep` short-circuit deleted | `test_todo_keep_leaves_pre_existing_list_alone` red, alone — FR4 is pinned by the row the runbook names |

## Critical Findings

None.

## Major Findings

None.

## Minor Findings

### m1 — `_plan_file` takes `path` and `rel` as independent parameters

`scripts/checkpoint.py:409`. The signature is
`_plan_file(path: Path, rel: str, body: str)`, and both call sites derive one
from the other on the same line (`:431`, and `:457` with `path` composed at `:443`).
Nothing makes them agree. `FilePlan`'s docstring (`:382`) states the invariant
"a plan cannot claim a `D` it will not perform" and grounds it in every
manifest-bearing plan coming from this one resolver — but the resolver's own
signature is the one place that invariant can be broken: a transposed argument
would unlink one file and record the other in the manifest, and FR7 would fail
silently, since `bash-post.sh` stages what the manifest says. `_plan_file(root,
rel, body)` composing `root / rel` itself would make the invariant structural
rather than conventional; `plan_todo` already holds `root` and needs `path`
only for its own `edit` precondition.

No caller is wrong today, which is why this is minor. The runbook specifies
this signature, so it is the runbook's shape rather than an executor's slip.

### m2 — `apply_plan`'s "No failure branch" is narrower than it reads

`scripts/checkpoint.py:460-468`. The docstring's claim is the point of the
whole restructure, and it is true of the *branching*: neither arm calls `err()`.
But `Path.unlink()` without `missing_ok=True` raises `FileNotFoundError` if the
file vanished after `_plan_file` sampled it, which exits 1 with a traceback,
before `write_manifest`, with the other half possibly already applied — the
exact outcome the change exists to remove, reached by a different route.

The window is not new, but it is wider: `plan_task` now stats the task file,
then `plan_todo` runs (stat, and a full `read_text` on the `edit` route), then
`apply_plan(task_plan)` unlinks. `missing_ok=True` closes it at zero cost, and
the `D` line stays correct either way — the file is absent afterwards, so
`git add -f` stages the deletion regardless of who performed it.

### m3 — no row covers the mirror of the fixed defect (`task: write` beside a failing `todo: edit`)

`tests/test_checkpoint.py:961`, `:989`, `:1017`. All three negatives carry
`task_clear()`, so they assert the task file is not *deleted*. The other half of
the same payload space — a task half that would *write* — has no row, and before
this change it produced the same class of defect with the opposite sign: a frame
written to disk, no manifest, nothing staged, and an error naming only
`todo.old_string`.

The gap is in what the suite documents rather than in what it detects: the
ordering mutation above reds the three clear-side rows, so a regression is
caught. A fourth negative differing only in its task half would state the claim
the code actually makes.

### m4 — "nothing touches the disk" is contradicted two paragraphs later

`CLAUDE.md:544` and
`docs/changelog/2026-09-13-…:25` both say nothing touches the disk until both
plans exist. The plan phase stats both files and, on the `edit` route, reads the
todo file whole. The changelog entry then makes a point of `keep` taking **no
stat** (`:39`) — which only reads as a guarantee if the other branches do take
one. "Nothing is written" is the claim that is true and is the one the outline
and `docs/design.md:244-246` actually make ("before either file is touched, so
every failure the two halves raise leaves the disk as it was" — accurate, and
correctly scoped to the two halves rather than to every `err()` in `main()`).

## Gap Analysis

| Design requirement | Status | Reference |
|---|---|---|
| FR2 — the three `err()` sites keep their field names and message text | covered | `checkpoint.py:402-405`, `:450-453`; assertions on `todo.old_string` + `not found`/`ambiguous`/`does not exist` |
| FR4 — a call silent about the list leaves it alone, no stat | covered | `plan_todo:444-445`; mutation-verified against `test_todo_keep_leaves_pre_existing_list_alone` |
| FR5 — the union's write semantics observably unchanged | covered | full pytest suite green; no row's expected outcome moved |
| FR6 — empty body ⟹ removal, staged; both routes | covered, and **widened** | `_plan_file:409`; the `edit`-to-empty route gained its first row (`:926`) |
| FR7 — everything written reaches the manifest | covered | `write_manifest` unconditional; `D`/`W` emitted only by `_plan_file` — see m1 for the one way this could still break |
| NFR1 — no git, no tmux | covered | no new import beyond `Literal` on an existing `typing` line |
| `apply_edit`/`apply_task`/`apply_todo` retired with no alias, every live citation moved | covered | grep over `scripts/ tests/ bin/ hooks/ skills/ docs/ CLAUDE.md`: no hit outside `plans/` and the frozen 2026-09-07 entry |
| `docs/changelog/` entry + index line + invalidated `design.md` prose, same pass | covered | `53aac3a` carries all four files with the code |
| `CLAUDE.md`'s three sites (`:543` claim, `_checkpoint_lib.py` bullet, Testing count + empty-body sentence + "Edit application" phrase) | covered | all three landed; count re-derived, not incremented |

## Summary

**Critical 0 · Major 0 · Minor 4.**

The guarantee the plan set out to land is in the code and is pinned by tests
that red under mutation. The four minors are one latent-defect shape in a
private signature (m1), one robustness edge the docstring overstates away (m2),
one coverage claim the suite makes narrower than the code (m3), and one prose
inaccuracy repeated in two documents (m4). None of them is reachable by a
well-formed payload.
