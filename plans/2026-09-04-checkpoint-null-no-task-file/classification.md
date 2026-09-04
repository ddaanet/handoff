# Classification — checkpoint `null` means "no task file"

## Requirements-clarity gate

- **Requirements source:** `plans/2026-09-03-brief-checkpoint-null-no-task-file.md` (brief)
- **Completeness:** Each FR has concrete mechanism: **Y** — no new FR; this is a
  conformance fix to the existing **FR6** ("A file whose body is empty is removed
  … File present ⟹ content pending"), and the mechanism is the already-correct
  empty-body delete path in `apply_task`. Each NFR has measurable criterion:
  **N/A** — no NFR in play; NFR1 (no git/tmux in the agent's Bash) is unchanged.
- **Routing:** Proceed to triage. Two open *decisions* remain (todo symmetry,
  absent-key semantics) — decisions for my human partner, not requirements gaps.

## Classification

- **Classification:** Moderate
- **Implementation certainty:** High — root cause located and verified in
  `scripts/checkpoint.py`; the delete path already exists and is correct.
- **Requirement stability:** Moderate — the primary FR is settled, but the
  brief leaves the `todo` question open and does not address absent-key
  semantics at all.
- **Behavioral code check:** **Yes** — changes two return branches in
  `validate_task`, adding a logic path. Moderate minimum.
- **Work type:** Production
- **Artifact destination:** mixed, dominant **production** — `scripts/` plus
  `agentic-prose` (`skills/handoff/SKILL.md`, `skills/precompact/SKILL.md`) and
  `investigation` (`docs/design.md`, `docs/changelog/`).
- **Evidence:**
  - Not a Defect route: observed ≠ expected, but the brief already discharged
    reproduce and root-cause. What remains is a scoped behavioral change with
    open design forks — the structured-bugfix investigation would re-run work
    already done.
  - `validate_task` (`scripts/checkpoint.py:264`) returns `("none", "")` for
    both `task is None` (267) and `content: None` (273); `apply_task` (358)
    returns `[]` for any action ≠ `"write"`. Verified by reading.
  - `is_empty_body` (`scripts/_checkpoint_lib.py:23`) + `apply_task`'s
    write-then-unlink is the working delete path the fix routes into.
  - Recall: `no-transition-special-cases` (no compat branch for the old `null`
    meaning), `genuine-red-not-missing-sut` (inverted tests red on assertion).

## Author-corrector coupling

Not an edify pipeline author skill. The in-repo coupling that *is* in scope:
`checkpoint.py`'s schema is documented in two skill bodies
(`skills/handoff/SKILL.md` ~98–108, `skills/precompact/SKILL.md` ~74–75), which
both describe `task` and `todo` identically — the wording that produced the
wrong call. Untouched and verified out of scope: the composer/parser pair
(`checkpoint.py` ↔ `handoff_drive_read`) and the two empty-body writers
(`checkpoint.py` ↔ `write-stage.sh` via `is_empty_body`).

**Author change:** checkpoint payload semantics for `task`.
**Coupled corrector:** none in the edify table; the coupled *documents* are the
two SKILL.md bodies. **Update needed: yes** — in scope.
