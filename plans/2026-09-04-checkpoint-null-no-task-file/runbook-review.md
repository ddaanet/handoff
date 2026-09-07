# Runbook review — the checkpoint payload names its actions

Reviewed: `plans/2026-09-04-checkpoint-null-no-task-file/runbook.md`, against
`outline.md`, `classification.md`,
`plans/2026-09-03-brief-checkpoint-null-no-task-file.md`, `recall-artifact.md`
and its seven memory files, `CLAUDE.md` + `memory/ddaanet/shared-claude.md`,
and the code under change.

Mode: fix-all. Every finding below is applied to `runbook.md`.

Overall the runbook is sound: the phase shape is right, Phase 0 earns its
place, the requirement mapping is honest, and the pairing discipline
(`green-is-not-evidence`) is visible in slices 1 and 5. One critical defect
would have broken two of the four skills; one major premise turned out to be
false when probed against real git; the rest are citation drift and two places
where a new test duplicated one already in the suite.

---

## Critical

### C1 — `main` validates `task`/`todo` for *every* skill, so D2 breaks `autoname` and `restart`

`scripts/checkpoint.py:485-486` calls `validate_task` and `validate_todo`
unconditionally, for all four `skill` values, and `:488-489` applies both.
That is harmless today only because an absent `task` key returns
`("none", "")`. Under D2 — every payload field required by key presence — an
absent key becomes an error, so **every `autoname` and `restart` payload exits
2 naming `task`**: 13 such payloads in `tests/test_checkpoint.py`, plus both
live skills, neither of which carries either field (verified by reading
`validate_autoname_forbidden_fields` / `validate_restart_forbidden_fields`,
which *forbid* both fields — so no payload can satisfy both rules).

The runbook's call-site enumeration named only "`main` (486–487) drops the
`root` argument from both validate calls", so an executor following it would
ship the break and then meet a wall of `autoname`/`restart` reds in the Phase 1
GREEN phase — the exact unrelated-red noise Phase 0 exists to prevent.

**Applied:** a new paragraph in Item 1.1 requiring all four calls to be wrapped
in `if skill in ("handoff", "precompact")`, with `write_manifest` left
unconditional (the empty manifest is `bash-post.sh`'s presence gate, and the
existing rows assert it). Slice 2 now names
`test_autoname_manifest_present_empty_neither_file_touched` (1408) and
`test_restart_manifest_present_empty_neither_file_touched` (1484) as the
regression guard, with an instruction to confirm they are green rather than
assume it.

---

## Major

### M1 — Phase 0's mapping claims exhaustiveness but four payload dicts cannot go through any factory

The mapping said "every site falls in exactly one bucket" and listed three
tests to leave literal. Four more must stay literal: the malformed payload
dicts at 428 (`task` carrying `old_string`/`new_string`), 448
(`content` + `old_string`), 468 (`old_string` alone), 487 (`new_string` alone).
Each is a key combination the factories exist to make unrepresentable, so no
factory can emit one. Their *other* field is filler and routes normally.

**Applied:** the left-literal list is now two groups, the second naming those
four with their line numbers and stating that Phase 1 deletes 448 and restates
the other three.

### M2 — "the phantom `D` was the only expected failure that redirect covered" is false

Probed against real git rather than assumed. `git add -f -- <path>` on a path
that is neither on disk nor in the index exits 128 with `fatal: pathspec
'<path>' did not match any files`. Item 1.1 slice 5 retires **one** route to
that state (a `D` line for a file that never existed). The other survives it: a
task or todo file **on disk but not in the index**, then cleared. Both paths
are gitignored, so nothing but this hook ever stages them, and any `git reset`
since the last checkpoint — or a file the user created by hand — leaves one in
exactly that state. Dropping the redirect would turn that benign case into a
reported failure on both channels, i.e. a false alarm on a legitimate flow.

`no-stderr-suppression` prescribes the remedy the runbook already invokes for
the other route: guard the expected failure away.

**Applied:** Item 2.1 is now two changes. A quiet index guard for `D` lines —
`[ -n "$(git -C "$cwd" ls-files -- "$rel")" ]`, explicitly *not*
`ls-files --error-unmatch`, which writes to stderr and would need the very
redirect being removed — then the redirect drop and the failure array. The
guard was verified against real git: it prints the path for one in the index,
nothing for one that never entered it, exits 0 either way, and survives a path
containing a space. The bats coverage went from one row to three: a
staged-then-deleted / never-in-the-index pair over one fixture, plus the
failure-channel row (stranded `.git/index.lock`), flagged as the load-bearing
one to watch fail first.

### M3 — two of slice 1's five new tests duplicate rows already in the suite

`test_task_string_content_written_manifest_records_w` and its todo twin assert
content-written plus the `W` manifest line. That is exactly what
`test_task_write_creates_file_manifest_records_w` (640) and
`test_todo_write_creates_file_manifest_records_w` (686) already assert, and
Phase 0 routes both through the factories — so they exercise the string form
with no edit at all. Adding the new rows would leave the suite carrying two
pairs of near-identical tests.

**Applied:** slice 1 is now "two new tests and three amended in place". The two
existing rows are amended only to tighten the body assertion from
`"real content" in …` to exact equality against the payload string, which is
the discrimination the union actually needs.

### M4 — `CLAUDE.md` has a third site stating the Write-or-Edit vocabulary, and a stale test count

Re-derived by grep (`spec-enumerations-need-rederiving`). The runbook named
`:535` (the `scripts/checkpoint.py` bullet) and `:798-799` (the Testing
enumeration). It missed `:12` — the Layout section's opening flow paragraph,
"per FR5/FR6 write semantics — a Write or Edit form, empty body ⟹ removed",
which states the vocabulary before the bullet does. Separately, `:785` claims
`tests/test_checkpoint.py` has "(89 tests)"; `pytest --collect-only` reports
**113** today, and this change moves it again.

**Applied:** Phase 4's `CLAUDE.md` bullet now lists three sites with line
numbers, plus an instruction to restate the count from a `--collect-only` run
rather than by arithmetic.

---

## Minor — citation drift

Every line number and test name in the runbook was checked against the real
files. These were wrong; all are fixed.

| Cited | Actual | Where |
|---|---|---|
| `main` (486–487) | 485–486 (applies at 488–489) | Item 1.1 call sites |
| 11 `task_write(...)` call sites | 10 — `grep -c` also matches the `def` at 112 | Item 0.1, twice |
| task_write used for todo at "532, 695, 717, 927–930" | 532, 695, 717, 930 — **927 is a task site** | Item 0.1 |
| `has_content`/`has_old`/`has_new` branching (316–340) | 319–341 (316 is the `isinstance` guard; 341 is the unreachable `raise`) | Item 1.1 |
| `file_path` block (275–290) | 275–289 | Item 1.1 |
| `skills/handoff/SKILL.md` ~96–97 | 98–99 | Item 3.1 |
| `skills/handoff/SKILL.md` ~101–105 | 104–108 | Item 3.1 |
| `skills/precompact/SKILL.md` ~64–65, ~72–73 | 65 (one line), 74–75 | Item 3.1 |
| `test_todo_null_untouched_list_left_alone` (~824) | 822 (824 is its `write_text`) | slice 1 |
| no-ops section: "~554–613" (Phase 0) vs "~551–636" (Phase 1) | comment header 549–551, defs 554/572/594/613, section ends 633 | both phases |
| `docs/design.md:212–222` | 212–223 — the paragraph's last line is 223 | Item 4.1 |
| `bats tests/*.bats` | `bats tests/hook-test.bats tests/checkpoint.bats` — the justfile names two files, not a glob | Verification |

Also fixed:

- **m9** — Phase 0 called the left-literal set "the four rows whose whole
  subject is a *wrong* `file_path`", then listed three such rows plus a
  four-row section that is not about `file_path` at all. Regrouped and
  recounted.
- **m10** — "Both bodies are under the ≤2000-word convention … so the budget is
  comfortable" was unmeasured. Measured: `skills/handoff/SKILL.md`'s body
  (frontmatter excluded) is **1971** words against the 2000 cap — 29 words of
  headroom, which is not comfortable in the abstract;
  `skills/precompact/SKILL.md` is 1018. The conclusion survives because the
  replacement is shorter, but the executor now has the baseline and the exact
  command.
- **m11** — the requirements table omitted **FR4**, which is the whole reason
  `todo` has a `keep` action and `task` does not. Added as a row.
- Consequential rewording: slice 5's "the phantom `D` that Phase 2's redirect
  existed to cover" now says "one of the two routes"; the Item 1.1 executor
  note no longer claims the `root` parameter is the only change `main` sees.

---

## Verified accurate — no change needed

Recorded so the next pass need not re-derive them.

- **Counts, all exact:** 61 `"task": None`, 57 `"todo": None`, 25 `file_path`
  occurrences, 1893 lines in `tests/test_checkpoint.py`. 113 tests collected
  (the runbook did not claim a number; it does now).
- **`scripts/checkpoint.py`:** `validate_task` 264, `_todo_file_path` 294–304,
  `validate_todo` 307, `file_path` requirement 326–328, `apply_edit` 344,
  `apply_task` 358, `apply_todo` 370, `write_manifest` 390 — all correct.
- **Test defs:** 207, 229, 428, 448, 468, 487, 506, 522, 554, 572, 594, 613,
  640, 663, 686, 708, 757, 780, 802 — all correct.
- **`docs/design.md`:** FR2 132–133, FR5 139–141, FR6 142–143, FR7 144–147;
  "One channel, one writer" heading at 212; `## Rejected alternatives` at 896.
  The FR text matches the runbook's mapping-table paraphrases. Grep confirms
  139–141 and 219–222 are the **only** two sites in `design.md` carrying the
  Write-form/Edit-form/`file_path` vocabulary.
- **`docs/changelog.md:39`** is indeed the index line for
  `2026-07-27-content-null-is-a-no-op.md`, and that entry is indeed the one
  this change reverses (it is what made `content: null` a no-op).
- **`scripts/bash-post.sh:36`** carries the `2>/dev/null`, inside an `if`
  condition, under `set -euo pipefail` — as described. The stranded-`index.lock`
  symptom is real: `git add -f` exits 128 and the redirect eats the whole
  message, leaving `staged 0, deleted 0`.
- **`tests/checkpoint.bats`** is where `bash-post.sh` is tested (rows at 236,
  249, 278, 297); `tests/test_checkpoint.py` does not cover it.
- **`/reload-plugins`** is real and verified for skill bodies specifically
  (`memory/ddaanet/stale-plugin-code.md:73`).
- **The mechanical mapping is meaning-preserving.** The load-bearing safety
  property of Phase 0 was unstated, so I verified and added it: `todo_keep()`
  preserves today's meaning for all 57 todo sites, and `task_clear()` changes
  the meaning of all 61 task sites — but **no test in the file pre-creates
  `.claude/handoff-task.md`** (the only `write_text` calls against these two
  paths are at 730, 759, 782, 824, all todo), so with slice 5's no-`D`-when-
  never-existed guarantee every one of the 61 keeps its exit code and its
  manifest assertion.
- **D2 costs no test-payload changes at the boundaries.** Scanned every
  `"skill": "handoff"` / `"skill": "precompact"` payload in the suite: all 65
  already carry both `task` and `todo` keys. The optionality being removed is
  unused there.
- **Out-of-scope claims hold:** `write-stage.sh` and `is_empty_body` are called
  but not modified; `tests/hook-test.bats`'s `file_path` hits are Write/Edit
  tool payloads, not checkpoint JSON.

## Not changed, flagged for the executor

Nothing blocking. The one judgment call left open is the wording of the
replacement prose in Item 3.1 — `directive-states-acts` says to include the
acts and cut the rationale, and the runbook already says so; the 29-word
headroom on `skills/handoff/SKILL.md` is the constraint to watch while writing
it.
