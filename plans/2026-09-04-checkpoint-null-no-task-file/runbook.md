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
| FR4 — `handoff-todo.md` is a scratch list the agent edits freely; the checkpoint is only the wrap-up path | 1 | 1.1 | This is why `todo` has a `keep` action and `task` does not: a call that says nothing about the list must not wipe it |
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
  61 `"task": None`, 57 `"todo": None`, 10 `task_write(...)` call sites (216,
  238, 514, 532, 648, 671, 695, 717, 927, 930 — a `grep -c` returns 11 because
  it also matches the `def` at 112), 25 `file_path` occurrences, 1893 lines,
  113 tests collected. `task_write` is deleted in this item — it is what the
  five replace, and it is currently used for `todo` payloads as well as `task`
  ones (lines 532, 695, 717, 930), which is part of why the two fields'
  contracts blurred.
  Requirements: D1, D2.
  Model: sonnet

  Mapping, exhaustive — every site falls in exactly one bucket:
  - `"task": None` → `task_clear()`. All 61.
  - `"todo": None` → `todo_keep()`. All 57.
  - `task_write(<…>/"handoff-task.md", body)` → `task_content(<dir>, body)`.
    Four sites: 216, 648, 671, 927.
  - `task_write(<…>/"handoff-todo.md", body)` → `todo_content(<dir>, body)`.
    Three sites: 695, 717, 930 — the ones where the task-shaped helper was
    already doing todo work.
  - a well-formed explicit todo dict carrying `file_path` +
    `old_string`/`new_string` → `todo_edit(repo, old, new)`. Four sites, all
    inside `test_todo_edit_*`: 742, 769, 792, 813.
  - **Not routed through a factory, left literal**, in two groups:
    - The three rows whose whole subject is a *wrong* `file_path` —
      `test_drifted_cwd_task_path_under_cwd_rejected` (229),
      `test_task_file_path_outside_claude_errors` (506),
      `test_todo_file_path_outside_claude_errors` (522) — plus the four
      `{"content": null}` rows in the no-ops section (554, 572, 594, 613;
      section comment at 549–551, section ends at 633). Phase 1 deletes all
      seven; routing them through a factory here would only have to be
      unpicked.
    - The four **malformed** payload dicts no factory can emit, since each is
      a key combination the factories exist to make unrepresentable:
      `test_task_with_old_string_new_string_errors` (428, a task dict with
      `old_string`/`new_string`),
      `test_todo_content_and_old_string_together_errors` (448),
      `test_todo_only_old_string_errors` (468),
      `test_todo_only_new_string_errors` (487). Their *other* field is filler
      (`"task": None` / `"todo": None`) and routes normally; only the dict
      under test stays literal. Phase 1 deletes 448 and restates the other
      three as the positive contract of the union.

  `test_drifted_cwd_writes_injected_root_never_cwd` (207) is **not** in the
  left-literal set — it passes the correct path, survives Phase 1, and routes
  through `task_content` like any other. Note that the directory it passes is
  the injected `root`, not the `repo` the checkpoint runs in; the factory's
  first parameter is whatever directory the call site names, so pass `root`
  there.

  **Why the mechanical mapping is meaning-preserving across Phase 1**, which
  is the property that makes it safe: `todo_keep()` becomes
  `{"action": "keep"}`, the same "leave it alone" the current `None` means, so
  all 57 todo sites are unaffected. `task_clear()` becomes
  `{"action": "clear"}`, which is *not* what `"task": None` means today — but
  verified by grep, **no test in the file pre-creates
  `.claude/handoff-task.md`** (the only `write_text` calls against these two
  paths are at 730, 759, 782 and 824, all todo). With slice 5 guaranteeing no
  `D` line for a file that never existed, every one of the 61 sites keeps its
  exit code and its manifest assertion.

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
  the 11 content/edit call sites (7 `*_content`, 4 `todo_edit`) — and it is
  deliberate: keeping a parameter
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
  replaced whole, including its `file_path` block (275–289) and its
  `old_string`/`new_string` guard; `_todo_file_path` (294–304) is deleted
  outright; `validate_todo` (307) has its `file_path` requirement (326–328)
  removed and its `has_content`/`has_old`/`has_new` branching (319–341)
  collapsed into one dispatch on `action`; `apply_task` (358) and `apply_todo`
  (370) become unlink-if-present with existence sampled before any write;
  `main` (485–486) drops the `root` argument from both validate calls.
  `apply_edit` (344), `write_manifest` (390) and `lib.is_empty_body` are
  unchanged.

  **`main` must also gate the two validate/apply pairs on the boundary
  skills**, and this is not a refinement — it is what keeps the change from
  breaking `autoname` and `restart`. Today `main` calls `validate_task` and
  `validate_todo` unconditionally for all four skills (485–486, then
  `apply_task`/`apply_todo` at 488–489), which is harmless only because an
  absent `task` key currently returns `("none", "")`. Under D2 an absent key
  is an error, so every `autoname` and `restart` payload — 13 of them in
  `tests/test_checkpoint.py`, and both live skills, neither of which carries
  either field — would exit 2 naming `task`. Wrap all four calls in
  `if skill in ("handoff", "precompact")`, leaving `manifest_lines` empty
  otherwise; `write_manifest` stays unconditional, since the empty manifest is
  what `bash-post.sh`'s presence-gate needs and what the `autoname`/`restart`
  rows already assert. Slice 2 below names the two existing rows that guard it.

  **The red is genuine and needs no stub.** Phase 0 left the factories as the
  single definition of both payload shapes; flipping their five bodies to the
  new shapes reds every new assertion on a failed assertion (the current
  validator rejects a bare string with `must be an object or null`), not on a
  missing symbol. Flip the factories in the RED phase, with the new tests.

  Slices:

  1. **External contract — the union is accepted and applied.** Two new tests
     and three amended in place, and the two `clear` rows are a pair over
     one fixture differing only in whether the file exists first, so neither
     can pass vacuously.
     The string-content case needs **no new row**:
     `test_task_write_creates_file_manifest_records_w` (640) and
     `test_todo_write_creates_file_manifest_records_w` (686) already assert the
     content plus the `W` manifest line, and Phase 0 routed both through the
     factories, so they exercise the string form with no edit at all. Amend
     them only to tighten the body assertion from `"real content" in …` to
     exact equality against the payload string — the discrimination the new
     union needs, and the reason to strengthen these two rather than duplicate
     them.
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
     line. (This is `test_todo_null_untouched_list_left_alone` (822) renamed
     and repointed at `{"action": "keep"}`.)

  2. **`null` and an absent key are each a named error — at the two boundaries
     only.** Parametrized over both fields, four cases: asserts exit 2 and
     that stderr contains `task` (resp. `todo`) for `"task": None` and for the
     key omitted from the payload entirely. Each case also asserts the target
     file was not created, so a validator that errored *after* writing cannot
     pass. The positive that keeps the rule from over-reaching already exists
     and needs no new row: `test_autoname_manifest_present_empty_neither_file_touched`
     (1408) and `test_restart_manifest_present_empty_neither_file_touched`
     (1484) each send a payload carrying neither field and assert exit 0 with
     an empty manifest. Those two are the regression guard for the `main`
     gating above — they red against an ungated `validate_task`, so confirm
     they are green at the end of this slice rather than assuming it; without
     the gate, the required-by-key-presence rule silently breaks two of the
     four skills.

  3. **An unrecognized or malformed action is a named error.** Parametrized:
     `{"action": "emty"}` on either field, `{"action": "keep"}` on `task`
     (which has no keep — the task frame is authored whole at every boundary),
     `{"action": "edit", …}` on `task` (this is
     `test_task_with_old_string_new_string_errors` (428) restated as the
     positive contract of the union), an object with no `action` key, and a
     value that is neither string nor object (a number). Each asserts exit 2
     and that stderr names the offending field.

  4. **The edit action's own required keys.** `{"action": "edit"}` carrying
     only `old_string`, and only `new_string`: each asserts exit 2 with stderr
     naming `todo`. These are `test_todo_only_old_string_errors` (468) and
     `test_todo_only_new_string_errors` (487) restated in action vocabulary —
     the same contract, reached through the dispatch instead of through key
     sniffing. `test_todo_edit_old_string_absent_errors`,
     `test_todo_edit_old_string_ambiguous_errors` and
     `test_todo_edit_requested_file_missing_errors` (757, 780, 802) keep
     their assertions unchanged; only their payload construction moves.

  5. **An empty body still removes, and `D` still records only a real
     removal.** `test_task_write_only_headings_removed_manifest_records_d`
     (663) is amended into a pair over the same payload — a body of headings
     alone: pre-existing file ⟹ removed and `D` recorded; never-existed file
     ⟹ nothing on disk and **no** `D` line. Same pair for
     `test_todo_write_no_items_removed_manifest_records_d` (708) with a
     `## Remaining` carrying no items. The never-existed halves retire the
     phantom `D` — one of the two routes to the `did not match any files`
     failure Phase 2's redirect was covering, which is why Phase 2 depends on
     this slice landing and why it still has to guard the other route itself.

  Rows deleted with the forms they cover, not inverted — an inverted test of a
  form that no longer exists is an absence-guard defending nothing:
  `test_task_content_null_no_file_path_noop` (554),
  `test_task_file_path_content_null_noop` (572),
  `test_todo_content_null_no_file_path_noop` (594),
  `test_todo_file_path_content_null_noop` (613) — the whole `{"content": null}
  no-ops` section, its comment header at 549–551 through its last line at 633,
  the outline names only the first two;
  `test_task_file_path_outside_claude_errors` (506);
  `test_todo_file_path_outside_claude_errors` (522);
  `test_todo_content_and_old_string_together_errors` (448, unrepresentable
  once a string carries no keys); `test_drifted_cwd_task_path_under_cwd_rejected`
  (229). Eight rows, so the suite goes from 113 collected to 105 before the new
  parametrized rows land. That last one is half of the session-root drift pair,
  and its surviving half `test_drifted_cwd_writes_injected_root_never_cwd` (207) —
  the mutation-checked negative that a drifted cwd gets nothing written into
  its `.claude/` — **must stay green**, since with `file_path` gone it is the
  only remaining coverage that the root comes from `HANDOFF_ROOT`.

  Interfaces:
  - `validate_task(payload: JSONDict) -> tuple[str, str]` — returns `("write", content)` or `("clear", "")`
  - `validate_todo(payload: JSONDict) -> tuple[str, str, str, str]` — returns `("write", content, "", "")`, `("edit", "", old, new)`, `("clear", "", "", "")` or `("keep", "", "", "")`
  - `apply_task(root: Path, action: str, content: str) -> list[str]` — manifest lines; `["D .claude/handoff-task.md"]` only when a file was actually removed, `[]` otherwise
  - `apply_todo(root: Path, action: str, content: str, old: str, new: str) -> list[str]` — same contract for the todo path; `"keep"` returns `[]` without touching the file

  Note for the executor: `validate_task` and `validate_todo` lose their `root`
  parameter — the only signature change, though `main` also gains the
  boundary-skill gate around all four calls. Neither returns `"none"` any
  more — `"clear"` and `"keep"` are distinct outcomes and `apply_*` must not
  collapse them.

## Phase 2: Stop swallowing a failed stage (type: inline)

- Item 2.1: `scripts/bash-post.sh:36` — drop `2>/dev/null` from
  `git -C "$cwd" add -f -- "$rel"` and report a failed `git add` on both
  channels rather than silently dropping the path from the counts. It is
  currently invisible — a stranded `index.lock` surfaces as `staged 0,
  deleted 0` on both channels (verified: `git add -f` exits 128 with
  `Unable to create … index.lock`, and the redirect eats all of it).
  Guarding the expected failure away rather than redirecting is the remedy
  this repo's convention prescribes; no redirect survives this item, so none
  needs an inline justification.
  Requirements: FR7, D4. Depends on: Item 1.1

  **The phantom `D` is not the only expected failure the redirect covered** —
  this was checked against real git rather than assumed, and the outline's
  claim that it was is wrong. `git add -f -- <path>` on a path that is neither
  on disk nor in the index exits 128 with `fatal: pathspec '<path>' did not
  match any files`. Item 1.1 slice 5 retires one route to that state (a `D`
  line for a file that never existed); the other survives it — a task or todo
  file that is **on disk but not in the index**, then cleared. It is
  gitignored, so nothing but this hook ever stages it, and any `git reset`
  since the last checkpoint (or a file the user created by hand) leaves it in
  exactly that state. Dropping the redirect would turn that benign case into a
  reported failure on both channels.

  So the item is two changes, not one. Guard the expected failure away: for a
  `D` line, stage the deletion only when the path is in the index —
  `[ -n "$(git -C "$cwd" ls-files -- "$rel")" ]` as the condition, and **not**
  `ls-files --error-unmatch`, which writes its own message to stderr and would
  need the very redirect this item is removing. Otherwise skip the path
  silently, uncounted, which is exactly today's outcome for that case and the
  only one that is true (nothing was staged, and nothing failed). Verified
  against real git: the guard prints the path for one in the index, nothing
  for one that never entered it, exits 0 either way, and survives a path
  containing a space. Then, with that case gone, drop the redirect
  and report what is left: collect the failures in a third array alongside
  `staged` and `deleted`, append `; failed to stage: <paths>` to both
  `summary` and `agent_ctx` when it is non-empty, and leave the existing
  message unchanged when it is empty. `set -euo pipefail` is in force and both
  git calls sit in `if` conditions, so a non-zero exit is already handled
  rather than fatal — what changes is that git's own explanation now reaches
  stderr.

  Three bats rows in `tests/checkpoint.bats` (which is where `bash-post.sh` is
  tested — the existing rows are named `bash-post: …`, at 236, 249, 278, 297;
  `tests/test_checkpoint.py` does not cover this script). The first two are a
  pair over one fixture, so neither can pass vacuously: a `D` line for a path
  that was staged and then deleted ⟹ counted in `deleted`, no failure
  reported; a `D` line for a path never in the index ⟹ silent, uncounted,
  still no failure reported. The third covers the failure channel itself: an
  unstageable path (a stranded `.git/index.lock` is the cheapest fixture and
  the motivating case) ⟹ the summary reports the failure and names the path.
  That third row is the load-bearing one — it is red today and green only once
  the redirect is gone — so watch it fail before writing the change.

## Phase 3: Both wrap-up skill bodies (type: inline)

- Item 3.1: `skills/handoff/SKILL.md` and `skills/precompact/SKILL.md` — rewrite
  the payload documentation to name the four actions. Both files in one item:
  they document one contract, `precompact/SKILL.md` defers to
  `handoff/SKILL.md` for the templates and the seam, and splitting them across
  items would degrade the only quality lever prose has.
  Requirements: FR2, FR5, Delivery. Depends on: Item 1.1

  Exact sites, each re-derived by grep against the current files:
  - `skills/handoff/SKILL.md` 98–99 — the two `task`/`todo` lines inside the
    JSON heredoc, carrying `"file_path": "<abs path to>/.claude/handoff-task.md"`
    and the `"<task content, or omit the whole field with null>"` placeholder.
    The `<abs path to>` interpolation disappears: the agent no longer composes
    a path it has to derive from a root it cannot read.
  - `skills/handoff/SKILL.md` 104–108 — "*`task` and `todo` are each the
    file's content, or `null` when there is nothing to say for that file*",
    with its `old_string`/`new_string` sentence. This paragraph is the
    defect's origin: it tells the agent `null` means "nothing to say", which
    for `task` reads as "no task file". Replaced by a list naming the actions
    and what each does.
  - `skills/precompact/SKILL.md` 65 — "*`task`/`todo` each either the drafted
    content or `null`*", inside the sentence introducing the call — and 74–75,
    the same two heredoc lines.

  The replacement states the acts and drops the rationale for why the form
  exists — the reader is executing, not reviewing the design. It must say what
  `{"action": "clear"}` does for `task` in one clause, since that is the case
  where an agent previously reached for `null` and got silence. The budget is
  **not** comfortable in the abstract and the baseline matters: measured
  today, `skills/handoff/SKILL.md`'s body (frontmatter excluded) is 1971 words
  against the ≤2000-word convention — 29 words of headroom —
  and `skills/precompact/SKILL.md`'s is 1018. The replacement is shorter than
  what it replaces, so this holds, but confirm with a word count rather than by
  eye:
  `awk 'NR>1 && /^---$/{p=1;next} p' skills/handoff/SKILL.md | wc -w`.

## Phase 4: The design record (type: inline)

- Item 4.1: `docs/design.md`, `docs/changelog/`, `docs/changelog.md`,
  `CLAUDE.md` — one item, because these are one prose artifact set and this
  repo's convention requires the changelog entry, its index line and the
  invalidated design prose in the same pass, not as a follow-up.
  Requirements: Delivery. Depends on: Item 1.1, Item 2.1, Item 3.1

  - `docs/design.md:212–223` ("One channel, one writer", the section heading
    through the paragraph's last line) states the payload as
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
  - `CLAUDE.md` — **three** sites, re-derived by grep rather than taken from
    the outline, which names two:
    - `:12`, the Layout section's opening flow paragraph — "per FR5/FR6 write
      semantics — a Write or Edit form, empty body ⟹ removed". This one the
      outline misses; it states the form vocabulary before the bullet does.
    - `:535`, the `scripts/checkpoint.py` bullet — "applies the `task`/`todo`
      Write-or-Edit forms (FR5; `task` is Write-form-or-null only)".
    - `:798–799`, the Testing section's enumeration of covered schema rows,
      which names `content`+`old_string` and `file_path` outside
      `$root/.claude/` verbatim — both rows are deleted in Item 1.1, so
      leaving them makes the enumeration describe tests that do not exist.
      The same sentence opens with "`tests/test_checkpoint.py` (89 tests)" at
      `:785`; that count is already stale (113 collected today) and this
      change moves it again, so restate it from a `--collect-only` run at the
      end of the pass rather than by arithmetic.

## Verification

`just precommit` — lints the manifest and settings, `shellcheck -x .bin/* bin/*
scripts/*.sh tests/*.bats` (which is what covers `bash-post.sh`), ruff /
`ruff format --check` / docformatter / mypy / ty over the Python, then
`bats tests/hook-test.bats tests/checkpoint.bats` (the two named files, not a
glob) and `pytest`. Run it before each commit; it is a required step, not a
suggestion.

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
