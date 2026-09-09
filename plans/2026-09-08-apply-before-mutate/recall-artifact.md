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
