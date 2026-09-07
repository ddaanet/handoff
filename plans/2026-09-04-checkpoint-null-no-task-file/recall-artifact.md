# Recall artifact — the checkpoint payload names its actions

Written at `/runbook`, 2026-09-07. No artifact existed at `/design` time; this
is the initial one. Planning-relevant entries only — execution-level detail
reaches executors through dispatch prompts.

The memory index (`memory/MEMORY.md`) was **not injected into this session's
context** (it sits at ~24.3KB against the loader's ~24.4KB drop point — the
open decision the task frame carries). Selection ran against the index file's
routing lines read from disk, which is the same routing table, not a degraded
substitute.

## Selected entries

- `memory/ddaanet/genuine-red-not-missing-sut.md` — why Phase 0 exists at all.
  A TDD red must fail on a **failed assertion**, never on a missing symbol or
  on ~118 unrelated payloads rejecting. Also: interface contracts one per
  line, and manufacture red by mutating the SUT in place.
- `memory/ddaanet/green-is-not-evidence.md` — structuring the new rejection
  rows so they cannot go vacuous: pair each negative with a positive over the
  **same fixture** differing only in the trigger input; a bare negative passes
  before the feature exists. Directly shapes the never-existed/pre-existing
  pair in Phase 1.
- `memory/ddaanet/spec-enumerations-need-rederiving.md` — the outline
  hand-counts the sites this change must touch. Re-derived mechanically at
  planning time: 61 / 57 / 11 / 25 / 1893 confirmed exactly; two gaps found
  (see below).
- `memory/ddaanet/remove-cleanly-no-vestigial.md` — cut the whole machinery in
  one pass; do not leave absence-guards defending a form that no longer
  exists, and convert a surviving guard into the positive contract of what
  remains.
- `memory/ddaanet/no-stderr-suppression.md` — Phase 2. Guard the expected
  failure away rather than redirecting; a surviving `2>/dev/null` needs an
  inline reason.
- `memory/ddaanet/design-doc-writing.md` — Phase 4. Living doc in the present
  tense, dated rationale in `docs/changelog/`, and the rejected-alternatives
  section is the one that stops a settled decision being re-litigated.
- `memory/ddaanet/directive-states-acts.md` — Phase 3. Both SKILL.md bodies
  are agent-facing directives: include the acts, cut the mechanism and the
  rationale for why the form exists.

Named by upstream (`classification.md`, `outline.md`) and already applied in
the outline's decisions, not re-read here:
`no-transition-special-cases` (no back-compat branch, user base of one),
`stale-plugin-code` (skill bodies snapshot at session start — the
producer/consumer skew in the Verification section).

## Deltas the re-derivation found against the outline

1. The outline names **two** rows to delete under `{"content": null}` — the
   two `task` ones. There are **four**: `test_todo_content_null_no_file_path_noop`
   and `test_todo_file_path_content_null_noop` too. The whole section goes.
2. `docs/changelog/2026-07-27-content-null-is-a-no-op.md` is the entry this
   change reverses — it is what *made* `content: null` a no-op. `CLAUDE.md`'s
   changelog convention requires a `> **Superseded**` blockquote on it. The
   outline does not list it.
3. Three schema rows the outline implies are deleted actually **survive,
   restated** as the positive contract of the tagged union:
   `test_task_with_old_string_new_string_errors`,
   `test_todo_only_old_string_errors`, `test_todo_only_new_string_errors`.
4. `tests/hook-test.bats` matches a `file_path` grep but its hits are
   Write/Edit **tool** payloads, not checkpoint JSON. Out of scope, confirmed
   by reading.
