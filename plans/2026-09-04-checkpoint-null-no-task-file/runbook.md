# Runbook — the checkpoint payload names its actions

Design: `outline.md` (this directory). Classification: `classification.md` —
Moderate / Production. Requirements source:
`plans/2026-09-03-brief-checkpoint-null-no-task-file.md`. Recall:
`recall-artifact.md`.

Requirement IDs are `docs/design.md`'s own FR numbering. `D1`–`D4` are the
outline's "Decisions this outline applies".

## Requirements mapping

| Requirement | Phase | Items | Notes |
|---|---|---|---|
| FR2 — payload validated against a schema, violation exits non-zero naming the field | 1 | 1.1 | The tagged union replaces key-combination sniffing; `null` and an absent key each become a named error |
| FR5 — todo supports incremental update; task is Write-form only | 1 | 1.1 | Restated in action vocabulary: `{"action": "edit"}` for todo, no edit action for task |
| FR6 — a file whose body is empty is removed; file present ⟹ content pending | 1 | 1.1 | Both routes to removal — explicit `{"action": "clear"}` and a write whose body is empty under `is_empty_body` |
| FR7 — everything written is staged via the manifest, deletions included | 1, 2 | 1.1, 2.1 | `D` records only a removal that happened; `bash-post.sh` stops swallowing a failed `git add` |
| D1 — tagged union, not sentinel strings | 1 | 1.1 | |
| D2 — every payload field required by key presence, no default | 1 | 1.1 | |
| D3 — removal is unlink-if-present; `D` only on an actual removal | 1 | 1.1 | |
| D4 — `bash-post.sh`'s `2>/dev/null` goes | 2 | 2.1 | |
| Delivery — the contract is documented in five places outside the code | 3, 4 | 3.1, 4.1 | Two skill bodies; `docs/design.md`, changelog + index, `CLAUDE.md` |

Verified out of scope, each by grep rather than by assumption:
`scripts/write-stage.sh` and `is_empty_body` (unchanged — `is_empty_body` is
called, not modified); the sentinel composer/parser pair; the
`autoname`/`restart` payloads (neither carries `task` or `todo`);
`tests/hook-test.bats` (its `file_path` hits are Write/Edit **tool** payloads,
not checkpoint JSON). No back-compat branch for the old shape — user base of
one, fix forward.

## Phase 0: Route every test payload through factories (type: general)

Load-bearing, and the reason it is its own phase: the moment the schema
changes, ~118 literal payloads red for reasons unrelated to the behaviour
under test, and Phase 1's new assertions are invisible in that output. This
phase carries **no behaviour change** — the factories emit today's dicts
byte-for-byte and the suite is green at its start and its end.

- Item 0.1: `tests/test_checkpoint.py` — introduce five payload factories
  beside the existing `task_write` helper (line 112) and route every literal
  `task`/`todo` payload value through them. Re-derived counts, current file:
  61 `"task": None`, 57 `"todo": None`, 11 `task_write(...)` call sites, 25
  `file_path` occurrences, 1893 lines. `task_write` is deleted in this item —
  it is what the five replace, and it is currently used for `todo` payloads
  as well as `task` ones (lines 532, 695, 717, 927–930), which is part of why
  the two fields' contracts blurred.
  Requirements: D1, D2.
  Model: sonnet

  Mapping, exhaustive — every site falls in exactly one bucket:
  - `"task": None` → `task_clear()`. All 61.
  - `"todo": None` → `todo_keep()`. All 57.
  - `task_write(repo/".claude"/"handoff-task.md", body)` → `task_content(repo, body)`.
  - `task_write(repo/".claude"/"handoff-todo.md", body)` → `todo_content(repo, body)`.
  - an explicit todo dict carrying `old_string`/`new_string` → `todo_edit(repo, old, new)`.
  - **Not routed through a factory, left literal:** the four rows whose whole
    subject is a *wrong* `file_path` —
    `test_drifted_cwd_task_path_under_cwd_rejected` (~229),
    `test_task_file_path_outside_claude_errors` (~506),
    `test_todo_file_path_outside_claude_errors` (~522), and the
    `{"content": null}` rows in the `no-ops` section (~554–613). Phase 1
    deletes these; routing them through a factory here would only have to be
    unpicked. `test_drifted_cwd_writes_injected_root_never_cwd` (~207) is
    **not** in that set — it passes the correct path, survives Phase 1, and
    is routed through `task_content` like any other.

  Verification: `pytest tests/test_checkpoint.py` green before and after, with
  the same test count. `git diff --stat` shows `tests/test_checkpoint.py` and
  nothing else.

  Interfaces:
  - `task_content(repo: Path, content: str) -> dict[str, str]` — returns `{"file_path": str(repo / ".claude/handoff-task.md"), "content": content}`
  - `task_clear() -> None` — returns `None`
  - `todo_content(repo: Path, content: str) -> dict[str, str]` — returns `{"file_path": str(repo / ".claude/handoff-todo.md"), "content": content}`
  - `todo_keep() -> None` — returns `None`
  - `todo_edit(repo: Path, old: str, new: str) -> dict[str, str]` — returns `{"file_path": str(repo / ".claude/handoff-todo.md"), "old_string": old, "new_string": new}`

  The `repo` parameter exists only to compose `file_path`, and Phase 1 drops
  it from all five signatures along with the field. That is a bounded edit —
  the ~11 content/edit call sites — and it is deliberate: keeping a parameter
  no body reads would leave exactly the vestigial residue this repo's
  removal convention forbids. `task_clear()` and `todo_keep()` take no
  parameter in either phase, which is why the 118 sites are touched once.

## Phase 1: The payload layer (type: tdd)

- Item 1.1: `scripts/checkpoint.py` — replace the `task`/`todo` payload layer
  with a tagged union: each field carries its content directly as a string, or
  an object naming an action. `file_path` is removed from both fields;
  `apply_task`/`apply_todo` already compose the real path from `HANDOFF_ROOT`,
  so the field was validated against a constant and discarded. `null` and an
  absent key each become a named schema error on both fields — the defect
  being fixed is an agent choosing a spelling that silently did the wrong
  thing, so the wrong spelling must fail loudly rather than acquire a meaning.
  `null` is untouched on `continue`, where it has one meaning.
  Requirements: FR2, FR5, FR6, FR7, D1, D2, D3.
  Depends on: Item 0.1

  Accepted shapes:
  - `task`: `"<content>"` or `{"action": "clear"}`.
  - `todo`: `"<content>"`, `{"action": "clear"}`, `{"action": "keep"}`, or
    `{"action": "edit", "old_string": …, "new_string": …}`.

  Call sites, enumerated: `validate_task` (`scripts/checkpoint.py:264`) is
  replaced whole, including its `file_path` block (275–290) and its
  `old_string`/`new_string` guard; `_todo_file_path` (294–304) is deleted
  outright; `validate_todo` (307) has its `file_path` requirement (326–328)
  removed and its `has_content`/`has_old`/`has_new` branching (316–340)
  collapsed into one dispatch on `action`; `apply_task` (358) and `apply_todo`
  (370) become unlink-if-present with existence sampled before any write;
  `main` (486–487) drops the `root` argument from both validate calls.
  `apply_edit` (344), `write_manifest` (390) and `lib.is_empty_body` are
  unchanged.

  **The red is genuine and needs no stub.** Phase 0 left the factories as the
  single definition of both payload shapes; flipping their five bodies to the
  new shapes reds every new assertion on a failed assertion (the current
  validator rejects a bare string with `must be an object or null`), not on a
  missing symbol. Flip the factories in the RED phase, with the new tests.

  Slices:

  1. **External contract — the union is accepted and applied.** Five tests, and
     the two `clear` rows are a pair over one fixture differing only in whether
     the file exists first, so neither can pass vacuously.
     `test_task_string_content_written_manifest_records_w` — asserts
     `.claude/handoff-task.md` holds the payload string exactly and the
     manifest holds the single line `W .claude/handoff-task.md`.
     `test_todo_string_content_written_manifest_records_w` — the same for
     `.claude/handoff-todo.md`.
     `test_task_clear_removes_pre_existing_file_manifest_records_d` — with
     `.claude/handoff-task.md` pre-created holding `## Current task\n\nstale\n`,
     asserts the file no longer exists and the manifest holds
     `D .claude/handoff-task.md`. This is the motivating incident's own case.
     `test_task_clear_never_existed_writes_nothing_no_d` — same payload, no
     pre-created file: asserts exit 0, the file still does not exist, the
     manifest file **is present** (`bash-post.sh`'s gate is its mere presence)
     and its text contains no `handoff-task.md` at all — neither `W` nor `D`.
     `test_todo_keep_leaves_pre_existing_list_alone` — with
     `.claude/handoff-todo.md` pre-created holding `## Remaining\n\n- untouched\n`,
     asserts the file's bytes are unchanged and the manifest names no todo
     line. (This is `test_todo_null_untouched_list_left_alone` (~824) renamed
     and repointed at `{"action": "keep"}`.)

  2. **`null` and an absent key are each a named error.** Parametrized over
     both fields, four cases: asserts exit 2 and that stderr contains `task`
     (resp. `todo`) for `"task": None` and for the key omitted from the
     payload entirely. Each case also asserts the target file was not created,
     so a validator that errored *after* writing cannot pass.

  3. **An unrecognized or malformed action is a named error.** Parametrized:
     `{"action": "emty"}` on either field, `{"action": "keep"}` on `task`
     (which has no keep — the task frame is authored whole at every boundary),
     `{"action": "edit", …}` on `task` (this is
     `test_task_with_old_string_new_string_errors` (~428) restated as the
     positive contract of the union), an object with no `action` key, and a
     value that is neither string nor object (a number). Each asserts exit 2
     and that stderr names the offending field.

  4. **The edit action's own required keys.** `{"action": "edit"}` carrying
     only `old_string`, and only `new_string`: each asserts exit 2 with stderr
     naming `todo`. These are `test_todo_only_old_string_errors` (~468) and
     `test_todo_only_new_string_errors` (~487) restated in action vocabulary —
     the same contract, reached through the dispatch instead of through key
     sniffing. `test_todo_edit_old_string_absent_errors`,
     `test_todo_edit_old_string_ambiguous_errors` and
     `test_todo_edit_requested_file_missing_errors` (~757, ~780, ~802) keep
     their assertions unchanged; only their payload construction moves.

  5. **An empty body still removes, and `D` still records only a real
     removal.** `test_task_write_only_headings_removed_manifest_records_d`
     (~663) is amended into a pair over the same payload — a body of headings
     alone: pre-existing file ⟹ removed and `D` recorded; never-existed file
     ⟹ nothing on disk and **no** `D` line. Same pair for
     `test_todo_write_no_items_removed_manifest_records_d` (~708) with a
     `## Remaining` carrying no items. The never-existed halves are what
     retire the phantom `D` that Phase 2's redirect existed to cover, so
     Phase 2 depends on this slice landing.

  Rows deleted with the forms they cover, not inverted — an inverted test of a
  form that no longer exists is an absence-guard defending nothing:
  `test_task_content_null_no_file_path_noop`,
  `test_task_file_path_content_null_noop`,
  `test_todo_content_null_no_file_path_noop`,
  `test_todo_file_path_content_null_noop` (the whole `{"content": null}
  no-ops` section, ~551–636 — the outline names only the first two);
  `test_task_file_path_outside_claude_errors` (~506);
  `test_todo_file_path_outside_claude_errors` (~522);
  `test_todo_content_and_old_string_together_errors` (~448, unrepresentable
  once a string carries no keys); `test_drifted_cwd_task_path_under_cwd_rejected`
  (~229). That last one is half of the session-root drift pair, and its
  surviving half `test_drifted_cwd_writes_injected_root_never_cwd` (~207) —
  the mutation-checked negative that a drifted cwd gets nothing written into
  its `.claude/` — **must stay green**, since with `file_path` gone it is the
  only remaining coverage that the root comes from `HANDOFF_ROOT`.

  Interfaces:
  - `validate_task(payload: JSONDict) -> tuple[str, str]` — returns `("write", content)` or `("clear", "")`
  - `validate_todo(payload: JSONDict) -> tuple[str, str, str, str]` — returns `("write", content, "", "")`, `("edit", "", old, new)`, `("clear", "", "", "")` or `("keep", "", "", "")`
  - `apply_task(root: Path, action: str, content: str) -> list[str]` — manifest lines; `["D .claude/handoff-task.md"]` only when a file was actually removed, `[]` otherwise
  - `apply_todo(root: Path, action: str, content: str, old: str, new: str) -> list[str]` — same contract for the todo path; `"keep"` returns `[]` without touching the file

  Note for the executor: `validate_task` and `validate_todo` lose their `root`
  parameter, which is the only signature change `main` sees. Neither returns
  `"none"` any more — `"clear"` and `"keep"` are distinct outcomes and
  `apply_*` must not collapse them.

## Phase 2: Stop swallowing a failed stage (type: inline)

- Item 2.1: `scripts/bash-post.sh:36` — drop `2>/dev/null` from
  `git -C "$cwd" add -f -- "$rel"` and report a failed `git add` on both
  channels rather than silently dropping the path from the counts. The
  phantom `D` was the only expected failure that redirect covered, and Item
  1.1 slice 5 removed it: with no manifest line naming a file that never
  existed, a failed `git add` is a real defect, and it is currently invisible
  — a stranded `index.lock` surfaces as `staged 0, deleted 0` on both
  channels. Guarding the expected failure away rather than redirecting is the
  remedy this repo's convention prescribes; no redirect survives this item, so
  none needs an inline justification.
  Requirements: FR7, D4. Depends on: Item 1.1

  Concretely: collect the failures in a third array alongside `staged` and
  `deleted`, append `; failed to stage: <paths>` to both `summary` and
  `agent_ctx` when it is non-empty, and leave the existing message unchanged
  when it is empty. `set -euo pipefail` is in force and the `git add` sits in
  an `if` condition, so a non-zero exit is already handled rather than fatal —
  what changes is that git's own explanation now reaches stderr. Add a bats
  row to `tests/checkpoint.bats` (which is where `bash-post.sh` is tested)
  covering a manifest line naming an unstageable path: assert the summary
  reports the failure and names the path. `tests/test_checkpoint.py` does not
  cover this script.

## Phase 3: Both wrap-up skill bodies (type: inline)

- Item 3.1: `skills/handoff/SKILL.md` and `skills/precompact/SKILL.md` — rewrite
  the payload documentation to name the four actions. Both files in one item:
  they document one contract, `precompact/SKILL.md` defers to
  `handoff/SKILL.md` for the templates and the seam, and splitting them across
  items would degrade the only quality lever prose has.
  Requirements: FR2, FR5, Delivery. Depends on: Item 1.1

  Exact sites:
  - `skills/handoff/SKILL.md` ~96–97 — the two `task`/`todo` lines inside the
    JSON heredoc, carrying `"file_path": "<abs path to>/.claude/handoff-task.md"`
    and the `"<task content, or omit the whole field with null>"` placeholder.
    The `<abs path to>` interpolation disappears: the agent no longer composes
    a path it has to derive from a root it cannot read.
  - `skills/handoff/SKILL.md` ~101–105 — "*`task` and `todo` are each the
    file's content, or `null` when there is nothing to say for that file*",
    with its `old_string`/`new_string` sentence. This paragraph is the
    defect's origin: it tells the agent `null` means "nothing to say", which
    for `task` reads as "no task file". Replaced by a list naming the actions
    and what each does.
  - `skills/precompact/SKILL.md` ~64–65 — "*`task`/`todo` each either the
    drafted content or `null`*", and ~72–73, the same two heredoc lines.

  The replacement states the acts and drops the rationale for why the form
  exists — the reader is executing, not reviewing the design. It must say what
  `{"action": "clear"}` does for `task` in one clause, since that is the case
  where an agent previously reached for `null` and got silence. Both bodies
  are under the ≤2000-word convention and the replacement is shorter than what
  it replaces, so the budget is comfortable; confirm with a word count rather
  than by eye.

## Phase 4: The design record (type: inline)

- Item 4.1: `docs/design.md`, `docs/changelog/`, `docs/changelog.md`,
  `CLAUDE.md` — one item, because these are one prose artifact set and this
  repo's convention requires the changelog entry, its index line and the
  invalidated design prose in the same pass, not as a follow-up.
  Requirements: Delivery. Depends on: Item 1.1, Item 2.1, Item 3.1

  - `docs/design.md:212–222` ("One channel, one writer") states the payload as
    a deliberate choice — `task`/`todo` "in the harness's own tool-call shape",
    `file_path` + `content` for a Write. This change reverses that rationale,
    so the paragraph is rewritten in the union's vocabulary rather than
    patched, and takes a pointer to the new changelog entry.
  - `docs/design.md:139–141` states **FR5** in Write-form/Edit-form vocabulary
    that ceases to exist. FR5's substance survives — incremental todo update
    is still supported — and is restated in action terms. **FR6 (142–143) is
    unaffected and is not to be touched**; it is the requirement the whole
    change exists to satisfy.
  - `docs/design.md`'s rejected-alternatives section (`## Rejected
    alternatives`, from line 896) gains the magic-string sentinel with its
    reasoning: a typo in a bare `"@empty"`/`"clear"` token is
    indistinguishable from content and is written as content — the original
    defect class at a new spelling — whereas `{"action": "emty"}` is a schema
    error naming the field. Nothing else in the repo carries that argument and
    it is the one a future session will re-propose; the first shape considered
    at the proof pass was itself a bare sentinel.
  - `docs/changelog/2026-09-07-the-payload-names-its-actions.md` — the
    write-time record. Leads with the motivating incident (2026-09-02, handoff
    0.13.1: a task frame stating a finished release was still unpublished
    survived into the next session), then the positive design. Five rejected
    alternatives: error on `null`; document the `""` workaround; **make `null`
    delete** (this outline's own approach until 2026-09-07, and the minimal
    fix, so it is the one a future reader will re-propose); bare magic-string
    sentinels; keeping `file_path` as a cross-project guard.
  - `docs/changelog/2026-07-27-content-null-is-a-no-op.md` — **the entry this
    change reverses.** It is what made `content: null` a no-op in the first
    place, and the outline does not list it. Per this repo's convention it is
    never edited for content; it gains a heading blockquote,
    `> **Superseded 2026-09-07** (see [the payload names its
    actions](2026-09-07-the-payload-names-its-actions.md))`, scoped to what
    actually changed. Its index line at `docs/changelog.md:39` stays as
    written.
  - `docs/changelog.md` — the new entry's one-line index entry, newest first,
    in the established form `- [<date> — Title](changelog/<file>.md) — hook`.
    No version suffix unless the release lands in the same pass.
  - `CLAUDE.md` — the Layout section's description of the checkpoint payload
    (the `scripts/checkpoint.py` bullet's "applies the `task`/`todo` Write-or-
    Edit forms (FR5; `task` is Write-form-or-null only)"), and the Testing
    section's enumeration of covered schema rows, which names
    `content`+`old_string` and `file_path` outside `$root/.claude/` verbatim —
    both rows are deleted in Item 1.1, so leaving them makes the enumeration
    describe tests that do not exist.

## Verification

`just precommit` — lints the manifest and settings, `shellcheck -x` over the
scripts and `.bats` files (which is what covers `bash-post.sh`), ruff /
docformatter / mypy / ty over the Python, then `bats tests/*.bats` and
`pytest`. Run it before each commit; it is a required step, not a suggestion.

**The producer and consumer of this schema go live at different times.**
`checkpoint.py` runs through the `bin/handoff-checkpoint` shim and is live the
moment it is written; both SKILL.md bodies are snapshotted at session start.
Between Item 1.1 and a reload, a live session emits the old payload into the
new validator, which rejects it — so `/handoff` and `/handoff:precompact` fail
outright in the session doing the work. That is the right failure, and the
remedy is `/reload-plugins` for the bodies, or `/handoff:restart`.

**Before dogfooding, establish which plugin root is loaded** — the
version-keyed marketplace cache or `--plugin-dir` — since it decides whether
editing the working tree changes anything live. Check `installed_plugins.json`,
or grep the transcript for `plugins/cache/<owner>/handoff/<version>/`. Then one
real `/handoff` call, the day it lands.

**A version bump is a delivery requirement, not a breakage question.** The
payload is an internal contract between two files shipping in the same plugin,
with no external producer, so it cannot desynchronize across a release
boundary — the markdown shape of neither output file changes and `CLAUDE.md`'s
breaking-change rule is untouched. But the marketplace cache is keyed by
version: a push under an unchanged version reaches no installed repo and
`/plugin update` re-fetches nothing. The release call stays my human partner's;
"no bump" is not among the outcomes that deliver the fix.
