# Phase 2 corrector — the docs the reordering invalidates

Subject: the four in-scope files of commit `1372767`, read against
`scripts/checkpoint.py` as it stands in the tree.

Verdict: **pass with four fixes applied.** Two are truth/convention defects,
two are wrap artifacts the item's own edits left behind. No UNFIXABLE.
`just precommit` green; `git diff 1372767 --stat -- scripts/ tests/` empty.

## What was checked, and against what

| Check | Source of truth | Result |
| --- | --- | --- |
| Test count `139` | `pytest tests/test_checkpoint.py --collect-only -q` re-run here | `139 tests collected` — holds |
| `existence sampled in the plan phase` | `_plan_file`, `checkpoint.py:415` (`existed = path.is_file()`), called from `plan_task`/`plan_todo` ahead of any `apply_plan` | true |
| whole-or-nothing guarantee | `main()`, `checkpoint.py:569-573` — both `plan_*` calls, then both `apply_plan`, then `write_manifest` | true, and scoped correctly (see below) |
| `is_empty_body` parenthetical | `_plan_file` calls `lib.is_empty_body(body)` on the resolved body before any write | true after fix 3 |
| `write-stage.sh` half of that sentence | unchanged in the diff | untouched, as required |
| Edit-application test claim | `test_todo_edit_old_string_absent/_ambiguous/_requested_file_missing` + `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` | all three assert `task_path.read_text() == task_before` and `not (…/"checkpoint-manifest").exists()`; the positive shares the fixture |
| `edit`-to-empty route claim | `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` | present, asserts `D .claude/handoff-todo.md` |
| `plan_task`/`plan_todo` citation | `docs/design.md:240` | rewired; no `apply_task`/`apply_todo`/`apply_edit` string survives anywhere in `CLAUDE.md`, `docs/design.md` or `docs/changelog.md` |
| New dangling `D<n>` citation | `rg -n '\bD[0-9]+\b' CLAUDE.md docs/` | only `D1`/`D2` inside `2026-08-13-restart-drive-repair.md` (self-defining) and `D19` inside `2026-07-29-…` (gitlore's, not this repo's). None in `CLAUDE.md` or `docs/design.md`. None introduced; the outline's `(D5)` was correctly rendered as `FR4` in the code and does not appear in the prose |
| Frozen records | `git show 1372767 --stat -- docs/changelog/` | one file, the new entry. `2026-09-07-the-payload-names-its-actions.md` untouched and carries no `Superseded` header |
| Index line | `docs/changelog.md:11` | above the 2026-09-07 row, one physical line, `- [2026-09-13 — Title](changelog/…) — <hook>`, no version, link resolves to a file on disk; hook shape matches both neighbours (defect → rejected remedies → what replaced it) |

### The guarantee's scope — the check that mattered most

Neither file overreaches. `docs/design.md`'s added sentence binds itself to
"every failure **the two halves** raise", and `CLAUDE.md`'s says outright that
the subject is "those two halves and their manifest, not every `err()`
reachable from `main()`", naming `compose_sentinel`'s read-back as firing
after both applies with the manifest already written, and `OSError` as
outside. Both match `main()`'s actual order:

```
plan_task → plan_todo → apply_plan ×2 → write_manifest → compose_directives → compose_sentinel
```

No sentence anywhere claims the checkpoint never fails after a write. Nothing
to narrow.

### Tense and genre

`docs/design.md`'s addition is present-tense current truth with no account of
prior behaviour; the "used to" account lives only in the changelog entry's
§What falls out, where it belongs. The entry is a write-time record: the
motivating fact first, the three remedies (the structural one in §The change,
two in §Rejected) with the stated reasons, and the close on what falls out.
Neither genre has leaked into the other.

## Fixes applied

**1. `docs/design.md:247` — multi-link footer missing its comma.** The two
changelog links sat on adjacent lines with no separator, so they render as one
run-on line. The repo's own convention (`:763-764`, `:1060-1061`) puts a comma
at the end of every link line but the last. Added.

**2. `docs/changelog/2026-09-13-…md` — a claim false of the landed code.** The
entry said `_plan_file` "is the sole producer of the three plan shapes". It is
not: `plan_todo`'s `keep` branch (`checkpoint.py:443-444`) constructs
`FilePlan("none", path, "", [])` directly. The consequence the sentence draws
("a plan cannot claim a `D` it will not perform") survives, since the
short-circuit produces the shape that names no act — so the claim was narrowed
to "the one place a plan naming an act is produced", with the `keep`
short-circuit and its FR4 rationale stated in the following sentence. That
also puts the outline's decision 5 (`keep` takes no stat) on the record, which
it otherwise reached no doc at all.

Not fixed, and deliberately: `FilePlan`'s own docstring
(`scripts/checkpoint.py:381-383`) makes the same imprecise claim. `scripts/` is
scope-OUT and signed off at the Phase 1 checkpoint, so it is left as found and
flagged here instead. It is cosmetic — the docstring's stated *reason* is
true — and the prose no longer echoes it.

**3. `CLAUDE.md` `_checkpoint_lib.py` bullet — "each half's" overreaches.**
`is_empty_body` is not reached on a `keep` half, which short-circuits ahead of
`_plan_file`. Changed to "on **a** half's resolved body, before anything is
applied"; the timing clause, which is the parenthetical's whole job, is exactly
true. `write-stage.sh`'s half of the sentence and the shared-function rationale
are untouched, as the prompt requires. The ragged 12-character line the edit
left ("applied) and") was reflowed in the same pass.

**4. `CLAUDE.md` Testing bullet — wrap artifact.** The insertion left
"empty-body removal" alone on a line. Reflowed the sentence span; verified by
`git diff --word-diff` that the only word-level change in that hunk is none —
whitespace only.

## Not flagged (out of scope, per the prompt)

m5, m7, m12, m14–m18; both `SKILL.md` bodies; `docs/design.md` outside the
§One channel, one writer write-semantics paragraph; every other `CLAUDE.md`
bullet; the open version bump.

## One discrepancy worth recording

`reports/item-2-1.md` records the amended commit as `99ce354`. `HEAD` is
`1372767` with the same subject and the same four files. The sha in that report
is stale (a later amend or rebase); nothing about its content claims are
affected — every one of them was re-verified here against the tree rather than
against the report.

## Verification

- `pytest tests/test_checkpoint.py --collect-only -q` → `139 tests collected`
- `git show 1372767 --stat -- docs/changelog/` → one file, the new entry
- `rg -n '\bD[0-9]+\b' CLAUDE.md docs/` → no new citation
- `git diff 1372767 --stat -- scripts/ tests/` → empty
- `just precommit` → green: jq manifest + settings lint, `shellcheck -x`,
  ruff check + format, docformatter, mypy, ty, `bats tests/*.bats` (164 ok),
  `pytest` (229 passed, 11 deselected)
- Tree holds only the three modified doc files and this report; no commit made.

> **Corrected at review, 2026-09-13.** This report states that `FilePlan`'s
> docstring was left as found because `scripts/` was scope-OUT. The commit
> carrying this report fixes it: the orchestrator applied the narrowing
> inline after reading the finding, since leaving it would have left the
> docstring contradicting the changelog sentence this report had just
> corrected. The edit is docstring prose only — `git diff` shows no change to
> `act`, `path`, `body` or `manifest_lines`, and `just precommit` was green
> before the amend. Recorded as F1 by the TDD audit
> (`tdd-audit.md`), whose second finding is that the wording came from
> the runbook's own `Interfaces:` bullet, which contradicts the same item's
> `keep` instruction.
