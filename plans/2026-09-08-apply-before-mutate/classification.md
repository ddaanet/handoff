# Classification — nothing is written until both halves resolve

## Requirements-clarity gate

- **Requirements source:** `plans/2026-09-04-checkpoint-null-no-task-file/reports/deliverable-review.md`
  §C1 (and minor m3), plus my human partner's ruling `c1=b` selecting the
  remedy from the three the report names.
- **Completeness:** Each FR has concrete mechanism: **Y** — no new FR. This is
  a conformance fix to **FR5/FR6/FR7**: the checkpoint applies a wrap-up whole
  or not at all, and every mutation it performs reaches the manifest. The
  mechanism is named by the ruling — resolve both files' resulting state and
  manifest lines before performing either mutation. Each NFR has measurable
  criterion: **Y** — NFR1 unchanged (no git, no tmux); the observable is that a
  payload whose `todo` half fails leaves the task file byte-identical and
  writes no manifest.
- **Routing:** Proceed to triage. The one open fork (which of the report's
  three remedies) was settled by my human partner before this invocation.

## Item enumeration

Composite invocation — three discrete items, all by **explicit bundling** (the
`/design` argument names each):

1. **C1** — a failed `todo` edit destroys the task frame. Behavioral: **yes**
   (new functions, changed logic path in the apply phase).
2. **m3** — `apply_todo` writes an empty body to disk before unlinking it,
   falsifying for its sibling the claim in `apply_task`'s own docstring.
   Behavioral: **yes**, same code path; subsumed by item 1's restructure rather
   than fixed beside it.
3. **Docs** — a `docs/changelog/` entry, its index line, and the
   `docs/design.md` + `CLAUDE.md` prose the reordering invalidates. Behavioral:
   **no**.

Items 1 and 2 are one code change and route together. Item 3 is required by
this repo's own convention in the same pass, not as follow-up, so it routes
with them rather than batching separately.

## Classification

- **Classification:** Moderate
- **Implementation certainty:** High — the defect is reproduced in the report,
  the remedy is chosen, and the apply phase is two functions and forty lines.
- **Requirement stability:** High — no open forks remain.
- **Behavioral code check:** **Yes** — splits each applier into a plan step and
  an apply step, moves three `err()` sites ahead of every mutation, and turns
  `apply_edit` from a writer into a pure body computation. Moderate minimum.
- **Work type:** Production
- **Artifact destination:** mixed, dominant **production** — `scripts/` and
  `tests/`, plus **investigation** (`docs/design.md`, `docs/changelog/`,
  `CLAUDE.md`). No `agentic-prose`: the two SKILL.md bodies already gained the
  `edit` preconditions in this session's earlier pass (M2/m13), and the
  reordering is invisible to a producer that sends a valid payload.
- **Evidence:**
  - `scripts/checkpoint.py` `main()` applies `apply_task` before `apply_todo`,
    and `apply_todo` can `err()` — which exits 2 before `write_manifest`. Read
    and confirmed this session.
  - Three `err()` sites sit inside the apply phase: `todo.old_string` for a
    missing file, and `not found` / `ambiguous` inside `apply_edit`.
  - Recall: `genuine-red-not-missing-sut` (red on an assertion; mutate the SUT
    in place), `green-is-not-evidence` (pair the negative with a positive over
    one fixture, differing only in the trigger), `remove-cleanly-no-vestigial`,
    `no-doc-history-references`, `commit-bundling`.

## Author-corrector coupling

Not an edify pipeline author skill.

**Author change:** the checkpoint's apply phase — when a mutation happens
relative to the failures that can stop it. **Coupled corrector:** none in the
edify table. **Coupled documents:** `docs/design.md` (§One channel, one writer
states the write semantics) and `CLAUDE.md` (its `checkpoint.py` bullet
narrates `apply_task`/`apply_todo` by name, including the sampled-before-write
claim this change makes true of both). **Update needed: yes** — both in scope.
