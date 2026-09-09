# Runbook — nothing is written until both halves resolve

Design: `plans/2026-09-08-apply-before-mutate/outline.md`, proofed item by
item 2026-09-10. Triage: `classification.md` — Moderate / Production.
Recall: `recall-artifact.md`.
Requirements source:
`plans/2026-09-04-checkpoint-null-no-task-file/reports/deliverable-review.md`
§C1 and §m3, with remedy (b) — plan then apply — chosen by my human partner.

The guarantee this runbook lands: `scripts/checkpoint.py` applies a wrap-up
whole or not at all. Each half resolves to a plan — the path, the act, the
body, and the manifest lines that record it — and every failure the checkpoint
raises itself happens while resolving. Only once both plans exist does anything
touch the disk. An `OSError` from the filesystem is outside the guarantee and
is not addressed here.

## Requirements mapping

| Requirement | Phase | Items | Notes |
|---|---|---|---|
| FR2 — a violation exits non-zero naming the offending field | 1 | 1.1 | the three `err()` sites keep their exact field names and message text; the validators are untouched |
| FR4 — a call silent about the scratch list leaves it alone | 1 | 1.1 | `keep` short-circuits to the empty plan ahead of the shared resolver, taking no stat |
| FR5 — the task/todo union's write semantics | 1, 2 | 1.1, 2.1 | observably unchanged; restructured into plan-then-apply |
| FR6 — a file whose body is empty is removed, and the removal staged | 1, 2 | 1.1, 2.1 | the emptiness test moves from a post-write file read-back to the resolved body, on both halves |
| FR7 — everything the checkpoint writes reaches the manifest | 1, 2 | 1.1, 2.1 | `write_manifest` stays unconditional; a wrap-up that fails now writes no manifest because it wrote nothing |
| NFR1 — no git, no tmux in the checkpoint | 1 | 1.1 | unchanged; no new subprocess, no new import |

**Out of scope**, and named so an executor does not widen into them: the
validators (`validate_task`, `validate_todo`, `_todo_edit_strings`) and the
union's vocabulary — their messages must not move; `scripts/bash-post.sh` and
the manifest format; the sentinel composer; `scripts/_checkpoint_lib.py`
(`is_empty_body` is called from a new place, not changed); both `SKILL.md`
bodies — a producer sending a valid payload cannot observe this change. The
remaining pass-2 minors (m5, m7, m12, m14, and the cosmetic set) are separate
work. Frozen write-time records are not edited: everything under `plans/`, and
`docs/changelog/2026-09-07-the-payload-names-its-actions.md` — which cites
`apply_task`/`apply_todo` at `:53` and keeps that citation, because it records
what was true when it was written.

**Corrected against the outline.** The outline cites `(D5)` for `keep`'s
no-stat guarantee. `D5` is defined nowhere in this repo — it appears only in
that outline line. The guarantee is FR4's, and FR4 is what the code and the
runbook cite. (`D2`/`D3` are already known not to resolve in `docs/design.md`;
that is pass-2 minor m12 and is not fixed here, but no new dangling citation
is added.)

## Phase 1: The apply phase resolves before it mutates (type: tdd)

- Item 1.1: `scripts/checkpoint.py` and `tests/test_checkpoint.py` — split
  each half's apply into a plan step and an apply step, so every `err()` the
  checkpoint raises happens before either file is touched, and so the todo
  half's emptiness test reads the resolved body rather than a file it wrote
  first. Requirements: FR2, FR4, FR5, FR6, FR7, NFR1.

  Slices:

  1. **Whole or nothing, and the `edit`-to-empty route stays intact.** Five
     rows in `tests/test_checkpoint.py`, over one fixture whose task half is
     identical throughout — a pre-existing `.claude/handoff-task.md` with
     recognisable content, plus `"task": {"action": "clear"}` — and whose todo
     half carries the trigger. Four of the five already exist in the file
     under the `todo` `edit` heading and are **extended in place**, not
     duplicated; each is renamed so its name states the second claim it now
     makes. None of the four names is cited outside
     `tests/test_checkpoint.py` (verified 2026-09-10 by grep over `CLAUDE.md`,
     `docs/` and `tests/*.bats`).

     - `test_todo_edit_old_string_absent_errors` →
       `test_todo_edit_old_string_absent_errors_task_file_survives`. Todo file
       holds one item; the edit's `old_string` matches nothing. Asserts exit
       2, `todo.old_string` and `not found` on stderr, the todo file's bytes
       unchanged, **the task file still present with its original bytes**, and
       no `.claude/checkpoint-manifest`.
     - `test_todo_edit_old_string_ambiguous_errors` →
       `test_todo_edit_old_string_ambiguous_errors_task_file_survives`. Todo
       file holds the same item twice; the edit's `old_string` matches both.
       Asserts exit 2, `todo.old_string` and `ambiguous` on stderr, the todo
       file unchanged, the task file still present with its original bytes,
       and no manifest.
     - `test_todo_edit_requested_file_missing_errors` →
       `test_todo_edit_requested_file_missing_errors_task_file_survives`. No
       todo file at all. Asserts exit 2, `todo.old_string` and `does not
       exist` on stderr, the task file still present with its original bytes,
       and no manifest.
     - `test_todo_edit_replaces_first_occurrence_stages_w` →
       `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` —
       the positive over the same task fixture, differing from the three
       negatives only in that the `old_string` matches exactly once. Asserts
       exit 0, the task file gone, the todo file holding the replacement (the
       edited item absent and its sibling still present), and the manifest's
       lines being exactly `D .claude/handoff-task.md` and
       `W .claude/handoff-todo.md`.
     - `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` —
       new. A pre-existing todo file whose only item the edit replaces with
       the empty string, leaving a `## Remaining` heading and nothing under
       it. Asserts exit 0, the todo file gone from disk, and
       `D .claude/handoff-todo.md` in the manifest. This is the route
       `apply_todo`'s docstring names as the whole reason its emptiness test
       reads the file, and it has no row today.

     **Evidence protocol.** The three negatives are the red: run them against
     unchanged `scripts/checkpoint.py` and record that each fails on its
     surviving-task-file assertion — not on a missing symbol, and not on the
     no-manifest assertion, which is green before and after. The positive and
     the `edit`-to-empty row are green against unchanged code and are
     characterisation, so each earns its evidence by a mutation of the landed
     implementation instead (below). Report the red output verbatim.

     Then the implementation. `main()` builds both plans, applies both, and
     calls `write_manifest` with the concatenated lines; `write_manifest`
     stays unconditional, since the empty manifest is `bash-post.sh`'s
     presence gate (FR7). `plan_task` and `plan_todo` replace
     `apply_task`/`apply_todo`: each resolves its action to a body — `clear`
     resolves to the empty string, so it reaches removal through FR6's own
     rule rather than a branch of its own — then hands that body to the shared
     resolver, which applies FR6 and samples existence, so a `D` line records
     only a removal that will actually happen. `plan_todo`'s `keep`
     short-circuits ahead of the resolver straight to the empty plan: it must
     not reach a rule that reads an absent body as a removal, and it takes no
     stat (FR4). `plan_todo`'s `edit` branch keeps its own explicit
     file-absent `err()` ahead of `edited_body`, so the second stat the
     resolver then takes is deliberate — a precondition check and an existence
     sample are different questions, and one saved stat does not justify
     coupling them. `apply_edit` becomes `edited_body`, returning the
     replacement instead of writing it, which is what lets its two `err()`
     sites run in the plan phase; there is no alias and no back-compat
     wrapper.

     **The rename reaches every live citation, re-derived rather than copied:**
     the two definitions and both call sites in `scripts/checkpoint.py`;
     `_todo_edit_strings`' docstring (`checkpoint.py:364`), which names
     `apply_edit`; `apply_todo`'s own docstring, whose two references to
     `apply_task` describe an asymmetry this change removes — with the emptiness
     test now reading a value on both halves, the docstring states the shared
     rule rather than the difference; and `tests/test_checkpoint.py:538`, which
     names `apply_edit` for the same TypeError reason. `docs/design.md:240` is
     item 2.1's.

     **Mutation checks, run after the suite is green, one at a time.**
     (a) Ordering: move the task half's `apply_plan` call back above the
     `plan_todo` call and confirm the three negatives red again and nothing
     else does. (b) Empty-body route: drop the emptiness test from the shared
     resolver and confirm `test_todo_edit_emptying_the_list_removes_it_...`
     reds — it will not be alone, since the existing `write`-route empty-body
     rows read the same resolver; record which rows red and confirm the new
     row is among them. (c) The positive: make the shared resolver emit `D`
     unconditionally on the removal route and confirm
     `test_todo_edit_and_task_clear_both_apply_...` and the never-existed rows
     red.

     **Restore protocol, non-negotiable.** Mutate `scripts/checkpoint.py` in
     place — never by relocating a test — and restore by inverting the exact
     string replacement, in the same Bash call that made it where possible.
     Do not stage a backup copy under `$TMPDIR`: `$TMPDIR` is not stable
     across Bash calls in this session, and a mutation whose restore route
     has evaporated is live code. After each restore, prove it: `git diff
     --stat scripts/checkpoint.py` clean against the committed state and the
     full suite green, before the next mutation.

  Interfaces:
  - `class FilePlan(NamedTuple)` — what one half will do to its file,
    resolved before anything is written. Frozen, like `Transition` beside it,
    and its three shapes are produced in one place so a plan cannot claim a
    `D` it will not perform.
  - `FilePlan.act: Literal["write", "remove", "none"]`
  - `FilePlan.path: Path` — composed from `root`; composing it is not a stat
  - `FilePlan.body: str` — the bytes to write; `""` unless `act == "write"`
  - `FilePlan.manifest_lines: list[str]` — `["W <rel>"]`, `["D <rel>"]`, or
    `[]`
  - `plan_task(root: Path, action: str, content: str) -> FilePlan`
  - `plan_todo(root: Path, action: str, content: str, old: str, new: str) -> FilePlan`
  - `edited_body(field: str, path: Path, old: str, new: str) -> str` — the
    first-occurrence replacement; errors naming `<field>.old_string` when
    `old` is absent or ambiguous, with today's message text
  - `apply_plan(plan: FilePlan) -> None` — performs the write or the unlink,
    or nothing; no failure branch
  - `_plan_file(path: Path, rel: str, body: str) -> FilePlan` — the shared
    resolver: an empty body under `is_empty_body` is a removal, existence is
    sampled here, `D` only when a file is there to remove
  - `write_manifest(root: Path, manifest_lines: list[str]) -> None` —
    unchanged signature and behaviour

  Verification for the item: `just precommit` green — jq manifest and settings
  lint, `shellcheck -x`, ruff/docformatter/mypy/ty over the Python, `bats
  tests/*.bats`, `pytest`. It calls bare `pytest` off the direnv-activated
  venv; there is no `uv run`.

## Phase 2: The docs the reordering invalidates (type: general)

- Item 2.1: `docs/changelog/2026-09-10-nothing-is-written-until-both-halves-resolve.md`
  (new), `docs/changelog.md`, `docs/design.md`, `CLAUDE.md` — record the
  change as a write-time entry and rewrite the present-tense prose it
  falsifies, in one pass. Requirements: FR5, FR6, FR7. Depends on: Item 1.1.
  Model: opus

  The changelog entry is dated the day it lands. Read `scripts/checkpoint.py`
  as item 1.1 left it before writing any of this — the entry states what
  landed, not what was planned. It leads with the motivating fact: a wrap-up
  whose todo half is malformed removed `handoff-task.md`, wrote no manifest,
  staged nothing, and reported an error naming only `todo.old_string`; and
  `task: {"action": "clear"}` beside a `todo` `edit` is not an exotic payload
  but the ordinary boundary where the task finished and the list has
  leftovers. Then the three remedies weighed and why the structural one won:
  hoisting the two `edit` checks ahead of the task half removes today's
  triggers and leaves the ordering unchanged, so the next apply-time failure
  anyone adds reopens the defect silently, and it counts `old_string`'s
  occurrences in a second place that can drift from the place acting on the
  count; writing the manifest for whatever was applied before exiting records
  the loss and stages it, and a frame written by a wrap-up that never reached
  a commit is gone outright, so a checkpoint reporting the deletion it did not
  intend is not better than one hiding it. Close on what falls out rather
  than being fixed beside it: with the edited body in hand at plan time the
  emptiness test reads a value on both halves, so an empty body is never
  written first on either. No `> **Superseded**` header on the 2026-09-07
  entry — its decisions all stand, and this is the ordering they are applied
  within.

  `docs/changelog.md` takes the entry's index line, newest first, above the
  2026-09-07 row. No version: the two most recent rows carry none, and the
  version bump for the release carrying this work is still open.

  `docs/design.md` §One channel, one writer: one sentence stating the
  guarantee positively — the checkpoint applies a wrap-up whole or not at
  all, both halves resolving to a plan before either file is touched — and
  the `apply_task`/`apply_todo` citation in that section's `file_path`
  paragraph (`:240`) rewired to `plan_task`/`plan_todo`. Present tense, no
  account of what the code used to do; that account is the changelog entry's
  job.

  `CLAUDE.md`'s `scripts/checkpoint.py` bullet claims existence is sampled
  before any write (`:543`); make that a claim about the plan phase, and add
  the whole-or-nothing guarantee in the same breath. The bullet names no
  `apply_*` function, so nothing else in it moves — confirm that by grep
  rather than by reading, since the bullet is long.

  All four edits land in one pass and one commit with item 1.1's code and
  tests: this repo's convention puts the changelog entry, its index line and
  the invalidated design prose in the same pass as the change, and the
  standing bundling rule puts what corresponds to a change in one commit.
  Item 1.1's slice commit is the one to carry them — with `just precommit`
  green, amend it (`git commit --amend`, subject unchanged) rather than
  adding a second commit. Nothing is pushed at this point, so the amend is
  safe; state in the report that it happened.
