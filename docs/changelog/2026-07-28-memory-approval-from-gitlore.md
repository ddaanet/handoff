# Memory-approval wording is discovered from gitlore, not duplicated (2026-07-28)

> **Superseded 2026-07-29** (see [The approval clause renders as a
> block](2026-07-29-approval-clause-renders-as-a-block.md)), on two points
> only: the clause is no longer interpolated into the block-1 sentence but
> printed as its own block between blank lines, and the unset-key branch no
> longer says the gitlore plugin looks disabled or points at `/plugin` — it
> names the key, says gitlore pins it at `SessionStart`, and asks for a
> restart. The discovery mechanism and the no-fallback decision stand.

`checkpoint_memory_directive`'s approval-body wording — one line per changed
memory file: kind (New/Update/Augment/Reduce/Remove), tier/slug, one-line
summary — used to be hardcoded here, a fourth independent copy alongside
gitlore's own three internal call sites (`post-tool-use.sh`,
`memory-commit-batch.sh`, `resolve.sh`), which had already drifted once
against each other. gitlore now owns this wording as a single file
(`reference/memory-approval-clause.txt`, read via
`gitlore_memory_approval_clause()`) and advertises its path through a new
`gitlore.memoryApprovalClauseFile` git-config key — seeded at gitlore install
and re-pinned every gitlore `SessionStart`, mirroring the exact discovery
mechanism handoff already uses for `gitlore.commitCommand` (a producer
plugin's own precedent, reused rather than invented). `checkpoint_memory_directive`
resolves the key via `git config --get`, reads the file, and interpolates its
content into the existing block-1 sentence; nothing else about the directive
(the with-commit/without-commit split, the `$msgfile`/`$trigger` paths, the
blockquote instruction) changes.

There is deliberately no fallback copy of the wording in this repo. The
clause is only ever needed while gitlore is genuinely active — a
gitlore-memory submodule registered without a working gitlore install
already makes the *rest* of this directive a dead letter, since nothing
would consume the IPC files it tells the agent to write, so a hardcoded
fallback string would just be one more instruction nothing downstream
honors. Instead, when the config key is unset or its file unreadable, the
function reports the gap explicitly — names the config key, says the
gitlore plugin looks disabled, and points at `/plugin` — and returns before
building any approval text; blocks 2a/2b (the with-commit/without-commit
write instructions) never fire without a resolved clause, so a broken
discovery path fails loud rather than silently dropping the FR11 approval
gate on handoff's side.
