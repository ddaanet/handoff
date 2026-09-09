# Recall artifact — nothing is written until both halves resolve

Written at `/design`, 2026-09-08.

The memory index (`memory/MEMORY.md`) was **not injected into this session's
context** — it measures ~24.5 KB against the loader's drop point, which is a
standing open decision in the task frame. Selection ran against the store's
filenames plus the prior job's own artifact
(`plans/2026-09-04-checkpoint-null-no-task-file/recall-artifact.md`), whose
curation covers the same code.

## Selected entries

- `memory/ddaanet/genuine-red-not-missing-sut.md` — the two negatives must red
  on a failed assertion. Also the rule that matters most here: **manufacture
  the red by mutating the SUT in place**, never by relocating the test.
- `memory/ddaanet/green-is-not-evidence.md` — pair each negative with a
  positive over the **same fixture**, differing only in the trigger input.
  That is exactly the three-row shape the outline specifies: one fixture, and
  the `old_string` matching or not is the only thing that moves.
- `memory/ddaanet/remove-cleanly-no-vestigial.md` — `apply_edit` becomes
  `edited_body` with no alias, and the two docstrings citing it by name move in
  the same pass.
- `memory/ddaanet/no-doc-history-references.md` — `docs/design.md` states the
  surviving guarantee positively; the account of what the code used to do
  belongs in the changelog entry, which is a write-time record.
- `memory/ddaanet/commit-bundling.md` — code, tests and docs ride one commit.

Carried from the prior job's artifact and not re-read:
`spec-enumerations-need-rederiving` (re-derive the sites rather than trusting a
hand-listed enumeration), `design-doc-writing` (the changelog entry plus its
index line plus the invalidated design prose, one pass),
`no-transition-special-cases` (no back-compat branch — user base of one).

## Live hazard this job hit already

Mutation-checking in this session mutated `checkpoint.py` against a backup
written to `"$TMPDIR/…"`, and `$TMPDIR` was set for the call that wrote the
backup and empty for the call that read it. The mutation was live with the
restore route broken. **Restore by inverting the exact string replacement**,
then prove it: grep for the mutation marker and re-run the suite. Briefed to
`craft` at `inbox/brief-mutation-check-restore.md`.

## Added at `/runbook`, 2026-09-10

Implementation-pattern selection. The index is still not in this session's
context, so selection ran against store filenames again.

- `memory/ddaanet/spec-enumerations-need-rederiving.md` — the outline
  hand-lists the citation sites the rename must reach. Re-derived
  mechanically before writing the runbook: `apply_task`/`apply_todo`/
  `apply_edit` appear live in `scripts/checkpoint.py` (definitions at 378,
  392, 411; prose citations at 364, 416, 420; calls at 440, 546-547),
  `tests/test_checkpoint.py:538` and `docs/design.md:240` — matching the
  outline exactly. Everything else is under `plans/` or
  `docs/changelog/2026-09-07-…:53`, both frozen write-time records that are
  not edited.
- `memory/ddaanet/plan-contracts-not-full-code.md` — the runbook states
  contracts; the `Interfaces:` block is the only verbatim element.
- `memory/ddaanet/outside-in-tdd.md` — the architecture is settled, so the
  slice's tests assert through the production entry point (a subprocess run
  of `checkpoint.py`), which is what the existing suite already does.
- `memory/ddaanet/uv-direnv-venv.md` — `just precommit` calls bare `pytest`
  off the direnv-activated venv; no `uv run`.
- `memory/ddaanet/design-doc-writing.md` — the changelog entry is a
  write-time record and `docs/design.md` is present-tense current truth; the
  2026-09-07 entry takes no superseding header.

## Post-explore gate, 2026-09-10

Exploration surfaced three things step 1 did not anticipate: the four
existing `test_todo_edit_*` rows already carry `task: {"action": "clear"}`,
so the outline's five rows are four extensions plus one new row rather than
five additions; `Transition(NamedTuple)` is the module's precedent for a
frozen record; and the outline's `(D5)` citation resolves nowhere in the
repo. None of these routes to a memory entry the selection above missed —
stated explicitly rather than left silent.
