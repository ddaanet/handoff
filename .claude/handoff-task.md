## Current task

The DESIGN.md restructure is finished and verified: `DESIGN.md` is present-tense
current truth (27 KB, down from 113 KB), `docs/changelog.md` indexes 27 dated
write-time records under `docs/changelog/`, and every cross-reference across
`CLAUDE.md`, `README.md`, six scripts, three test files,
`skills/handoff/references/design.md` and the memory tier points at the new
paths. Mechanical no-loss is down to three residue lines (the replaced
living-doc header), the index is bijective with the record files, every link
resolves, and `just precommit` is green. An adversarial reviewer found seven
defects plus one regression in my own fix; all were confirmed at source and
resolved. The approved gitlore memory message is written.

A brief then arrived at the repo root — `brief-docs-plans-layout.md`,
propagating a documentation layout across the ddaanet plugin family. David's
call: this restructure lands on its own, then the layout migration follows as a
separate change adopting the reference format.

The migration's exact requirements, which must survive verbatim:

- Reference index line: `- [YYYY-MM-DD — Title](changelog/YYYY-MM-DD-slug.md) — hook (vX.Y.Z)`, **newest first**. Ours is oldest-first, `- YYYY-MM-DD [Title](changelog/...) — hook`, no version.
- Moves: `git mv DESIGN.md docs/design.md`; the four loose prospective design docs in `docs/` to `plans/`; `docs/superpowers/{specs,plans}/` to `plans/`.
- Brief constraints: use `git mv` so history shows a rename, not delete-plus-add; `CLAUDE.md` updates in the same commit as the paths it names; do **not** touch `plugin-dev/` (vendored git subtree); the `.DS_Store` / `._*` cleanup is a separate commit; grep for `DESIGN.md` and `docs/superpowers` before declaring done.
- Reference implementation: `/Users/david/code/claude-plugin-dev`, commits `c37f3cb` (split DESIGN.md) and `1c9999c` (specs to plans/). Read-only — it is another repo.

## Open decisions

- Whether adopting the reference format includes the trailing `(vX.Y.Z)` tag on
  all 27 backfilled index lines. The reference carries one per line; the brief
  says only that the version goes in the pointer line when there is one.
  Mapping 27 records to the releases that shipped them is git-tag archaeology,
  and the default stated before the decision was to skip it for the backfill.