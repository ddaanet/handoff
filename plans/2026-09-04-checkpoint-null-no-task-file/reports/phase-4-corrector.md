# Phase 4 checkpoint review — Item 4.1, the design record

Reviewed `2b6ac63` against `scripts/checkpoint.py`, `scripts/bash-post.sh` and
`tests/test_checkpoint.py` as the authority. Three fixes applied, all to
`CLAUDE.md` and `docs/design.md`. `just precommit` green after them: 164 bats,
218 pytest passed + 11 deselected, `tests/test_checkpoint.py` collecting 128.
Not committed. Working tree carries only the fixes below plus this report.

## Fixes applied

### 1. `(D3)` / `(D4)` were dangling plan-local ids — Major

`CLAUDE.md:544` closed the removal-semantics sentence with `(D3)` and
`CLAUDE.md:666` closed the `2>/dev/null` sentence with `(D4)`. Those are
decision ids private to
`plans/2026-09-04-checkpoint-null-no-task-file/runbook.md:20-23`
("D3 — removal is unlink-if-present; `D` only on an actual removal",
"D4 — `bash-post.sh`'s `2>/dev/null` goes"). `CLAUDE.md` and `docs/design.md`
share one id namespace — `FR<n>`/`NFR<n>`/`FR-G`/`FR-H`, all defined in
`docs/design.md` — and nothing outside the plan directory defines `D3` or `D4`.
A reader of `CLAUDE.md` cannot resolve them, and the runbook is a write-time
artifact that will not be maintained as the code moves.

Replaced each with a citation of the new changelog entry, which is the form
every neighbouring bullet uses for reasoning that lives elsewhere
(`See docs/changelog/<file>.md.`). That also gives both bullets the pointer the
convention wants and neither had.

### 2. `docs/design.md` was in change-report voice — Minor

`docs/design.md:227-229` read *"because the defect being fixed was an agent
choosing a spelling that quietly did the wrong thing"* and *"so the field **was**
validated against a constant and discarded"*. The doc's own stated contract
(`CLAUDE.md`, and `docs/design.md:7-11`) is present tense, current truth,
with the write-time narrative in `changelog/`; "being fixed" reports work in
flight and "was validated … and discarded" describes a field that no longer
exists rather than the shape that does. Restated present-tense with the same
two arguments intact:

- the named-error rule now reads *"because a spelling that quietly does the
  wrong thing is the defect this shape exists to prevent — a wrong one has to
  fail loudly rather than acquire a meaning"*;
- the `file_path` clause now reads *"so a payload-supplied one would ask the
  agent to derive a path from a root it cannot read, only to be checked
  against the one the write uses anyway"* — which is the actual argument, and
  is what the changelog's fifth rejected alternative expands.

Left alone: *"which is the case an agent used to reach for `null` and get
silence"*. Contrast with a superseded shape is in-house style in this file
(`docs/design.md:243`, `:306`, `:618` all do it), and that clause is what
explains why `task` has no `keep`.

### 3. A 92-column line left by the Phase-2 sentence — Minor

The `bash-post.sh` sentence inserted at `docs/design.md:258` left the following
line at 92 columns in a paragraph that wraps at ~76. Reflowed the three lines.
No wording change.

## Verified against the code, no change needed

Every factual claim in the five files was checked against
`scripts/checkpoint.py` / `scripts/bash-post.sh` at `HEAD`, not against the
runbook. All hold:

- **The union's vocabulary.** `clear` on both fields, `keep` and `edit` on
  `todo` alone — `validate_task` (`scripts/checkpoint.py:264-283`) accepts a
  string or `{"action": "clear"}` and nothing else; `validate_todo`
  (`:286-314`) adds `keep` and `edit`. `task` receiving `keep` or `edit` is a
  named error (test rows `task_keep_rejected`, `task_edit_rejected`).
- **Required by key presence; `null` and an absent key are each named.** Both
  validators error naming the field on the missing key, and a `null` value
  falls through to the type error naming the field (`got null`). Confirmed by
  running, not by reading.
- **The `main` gate.** `scripts/checkpoint.py:501` is literally
  `if skill in ("handoff", "precompact"):` wrapping both `validate_*` and both
  `apply_*`, exactly as the changelog's "The change" section states.
- **Removal.** `apply_task` (`:350-366`) samples `existed` before any write and
  never writes an empty body first; `apply_todo` (`:369-402`) samples it below
  the `keep` branch and returns `D` only `if existed`. The claim that a `D`
  line records only a real removal holds on both. `unlink-if-present on both
  routes` is the same wording both function docstrings use, so the prose does
  not diverge from its authority.
- **`file_path` was validated against a constant and discarded.** Confirmed at
  the pre-change revision: `git show 5484287:scripts/checkpoint.py` compares
  `Path(file_path).resolve()` against `(root / HANDOFF_REL_TASK).resolve()` and
  then never reads the value again — `apply_task` composes the path itself.
- **The phantom `D` and its two routes.** `git show 5484287` confirms the old
  `apply_task` wrote the body, unlinked it, and emitted `D` unconditionally.
  The second route is the one `scripts/bash-post.sh:38-42` names: both paths
  are gitignored, so a `git reset` or a hand-written file leaves one on disk
  but untracked.
- **`bash-post.sh`'s failure channel.** A path that could not be staged is
  named on both channels (`scripts/bash-post.sh:86-89`), and the `ls-files`
  guard reads its own exit status rather than inferring from empty output
  (`:53-58`) — both exactly as `CLAUDE.md:663-669` and `docs/design.md:257-258`
  describe.
- **`test_drifted_cwd_writes_injected_root_never_cwd`** exists
  (`tests/test_checkpoint.py:223`), so the fifth rejected alternative's claim
  about where the real coverage lives is checkable and true.

**Every payload shape written into any of the five files was run against
`scripts/checkpoint.py`**, not reasoned about: `{"action": "clear"}` (rc 0),
`{"action": "keep"}` (rc 0), `{"action": "edit", "old_string", "new_string"}`
(rc 0, first occurrence replaced, `W` in the manifest), `{"action": "emty"}`
(rc 2, `handoff-checkpoint: task.action: must be "clear", got "emty"` — the
field is named, as the changelog and `docs/design.md:915-916` both claim), and
`"task": ""` against a pre-existing file (rc 0, file removed,
`D .claude/handoff-task.md` in the manifest — which is what makes the
"Document the `""` workaround" rejected alternative's premise true).

## The five leads

1. **Factual claims** — all check out, above.
2. **Rejected alternatives are arguments, not labels.** All five carry the
   reason they lost. **Make `null` delete** is the strongest of them and the
   one the runbook flagged: it names itself as this change's own approach until
   2026-09-07 and as the smallest diff, then gives the reason it fails —
   `null` must stay a no-op on `todo` under FR4, so the payload ends up with
   one spelling meaning "remove" on one field and "leave alone" on the other,
   "the original defect with its polarity changed, and now with a precedent
   making it look intentional." A future session re-proposing it meets that.
   **Error on `null`** and **Keep `file_path`** are the other two that could
   have gone label-shaped and did not: each concedes what the option does buy
   before saying what it leaves behind.
3. **The superseding blockquote's scope.** Correct. It says "scoped to the
   remedy, not the diagnosis" and then keeps the diagnosis explicitly —
   "Writing the literal string `null` into the file was a real defect and had
   to stop" — before naming what was reversed. Form matches the nine existing
   blockquotes (`> **Superseded <date>** (see [title](sibling.md))`), and it
   heads the file rather than a section because the whole entry is what this
   reverses. The 2026-07-27 body is untouched; its index line is unchanged.
4. **The index line.** Newest-first at the top, established form, one physical
   line, no version suffix — and no entry in `docs/changelog.md` carries one
   (`grep -c "v[0-9]"` → 0), so this matches its neighbours rather than merely
   the convention. Its length and how much it says are in line with the
   2026-08-15 and 2026-08-14 entries above it.
5. **Present tense / no annotation.** Two clauses were not, and are fixed
   above. Nothing was appended in a dated or "as of" voice; "Last updated:
   2026-09-07" is the file's own standing header line, not an entry. The
   changelog pointer at `docs/design.md:234` uses the file's own convention —
   a bare link on its own line closing the paragraph, as at `:390`, `:471`,
   `:905`, `:923`.
6. **The Testing enumeration.** Each named row exists in
   `tests/test_checkpoint.py`: `null`/absent on each field
   (`test_task_or_todo_null_or_absent_errors_naming_field`, ids `task_null`
   / `task_absent` / `todo_null` / `todo_absent`), an action outside the
   field's vocabulary, an object with no `action` key, a value that is neither
   string nor object, and an `edit` missing or mistyping either string (all
   six shapes are ids in `test_task_or_todo_action_vocabulary_errors_naming_field`).
   The two rows the item required deleting — `content`+`old_string` together
   and `file_path` outside `$root/.claude/` — are gone from both the tests and
   the enumeration. Count re-run: `pytest tests/test_checkpoint.py
   --collect-only -q` → **128 tests collected**, which is what the sentence
   says.
7. **Sweep for anything Phases 1–3 invalidated.** Grepped `docs/design.md` and
   `CLAUDE.md` for `file_path`, `Write form`/`Edit form`/`Write-or-Edit`,
   `2>/dev/null`, `old_string`, `content: null` and `no-op`. Every surviving
   hit is either the new prose describing the union or unrelated
   (`no-op` on hook silence, `old_string` in the `edit` action's own
   description). Both `SKILL.md` bodies agree with what `docs/design.md` and
   `CLAUDE.md` now say about the union, so the five documentation sites are
   consistent with each other and with the code.

## Findings not fixed — out of this item's scope

Neither is a defect in the prose under review; both are reported for the
orchestrator to route.

1. **`scripts/checkpoint.py:5-6`** — the module docstring still says *"applies
   the task/todo Write-or-Edit forms (FR5/FR6)"*. That vocabulary ceased to
   exist in Phase 1. It is the last site in the repo outside `plans/` and
   `docs/changelog/` carrying it. `scripts/` is explicitly out of scope for
   editing in this dispatch, so it is untouched; it is a one-line Phase-1
   residual.

2. **`CLAUDE.md:820-823`, pre-existing and not invalidated by this change** —
   the sentence enumerating `tests/test_checkpoint.py`'s coverage attributes
   to it "empty-body removal through both writers (`checkpoint.py` and
   `write-stage.sh`)" and "`bash-post.sh` (manifest absent, manifest present,
   a sentinel left untouched)". Neither script is exercised anywhere in that
   file: `grep -n "write-stage\|stage" tests/test_checkpoint.py` returns one
   hit, a test *name*. `write-stage.sh` is covered in
   `tests/hook-test.bats:543-610` and `bash-post.sh` in `tests/checkpoint.bats`
   — which the same `CLAUDE.md` bullet says four paragraphs earlier, so the
   file contradicts itself. This predates the change
   (`git show 5484287:tests/test_checkpoint.py | grep write-stage` → nothing),
   so it is not something Phases 1–3 invalidated, and I left it rather than
   widening the diff past the item. Worth a line in a later pass.

## Done criteria

- `just precommit` green: 164 bats, 218 pytest passed + 11 deselected;
  `tests/test_checkpoint.py --collect-only -q` → 128.
- Every documented payload shape run against `scripts/checkpoint.py`.
- Working tree: `M CLAUDE.md`, `M docs/design.md`, plus this report. No
  commit. A scratch git repo created under `$TMPDIR` for the payload runs
  landed in the repo root and was removed; `git status` is clean of it.
