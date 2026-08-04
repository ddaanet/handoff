## Brief: import the shared ddaanet conventions into CLAUDE.md

2026-08-01 — written from `micro`, where the change originated.

### Decisions

- The `ddaanet` tier now carries `shared-claude.md`: the always-in-context
  tier of conventions binding on every repo that mounts the tier. Each
  mounting repo imports it as the last line of its own `CLAUDE.md`:
  `@memory/ddaanet/shared-claude.md`
- Deliberately *not* named `CLAUDE.md`. A file by that name inside
  `memory/ddaanet/` is auto-injected whenever an agent touches that
  directory — the memory store is not a place conventions apply — and it
  would collide with the repo's own root `CLAUDE.md`.
- What moved into it is the *acted-inline* class of rule: one that must
  change default behaviour without being looked up. A fact an agent should
  *find* when it meets a symptom stays a memory file with a routing line in
  `MEMORY.md`. 24 such rules were relocated whole out of the index.
- Verified today in `micro`, in a fresh session: the `@` import resolves
  across the memory-submodule *and* the tier boundary, and the file's
  contents appear in the session's `claudeMd` context block. The nested
  checkout needs no special handling.

### Constraints

- **Blocking prerequisite — the file is not published yet.** `micro`'s tier
  HEAD is `d7f48bb`; `origin/live` is still `f221afb`, and
  `shared-claude.md` does not exist there. Nothing below can run until
  `micro` has pushed. Check first:

```sh
git -C /Users/david/code/handoff/memory/ddaanet fetch origin live
git -C /Users/david/code/handoff/memory/ddaanet cat-file -e origin/live:shared-claude.md \
  && echo PUBLISHED || echo "not published — stop here"
```

- Do not add the `@` line before `/gitlore:merge` has brought the file in.
  A premature edit looks correct and loads nothing. Whether Claude Code
  reports an unresolvable `@` import at all is unverified — do not count on
  noticing it.
- This repo's tier checkout is stale (102 entries against `micro`'s 104,
  still on the underscore slugs) and `memory/` has uncommitted changes
  (`MEMORY.md` modified, tier pointer moved) — settle those before merging.
- **This repo's index is over the cap.** `memory/MEMORY.md` is 26,892 bytes
  against a 24,985-byte loader cap that drops the tail with no warning:
  roughly 2KB of pointers at the end of the index are not being loaded at
  all right now. The merge retires 28 facts and drops the 24 relocated
  rules' pointers, which is what brings it back under.
- `shared-claude.md` is 14,070 bytes and is paid for by every session in
  every mounting repo. Nothing warns when it grows. Keep additions to rules
  that change what the agent does by default.

### Rejected approaches

- Trimming the memory index to fit. Shortening a pointer's hook loses the
  routing that makes it findable. The acted-inline rules had to move
  *whole*, into a file with no cap, not be compressed.
- `memory/ddaanet/CLAUDE.md` — auto-injected on directory access, collides
  with the repo's own root file.
- Copying the conventions into each repo's `CLAUDE.md`. Five copies drift;
  the point is one file, one edit, every consumer.

### Procedure

1. `/gitlore:merge`, then confirm:
   `test -f memory/ddaanet/shared-claude.md && echo ok`
2. Read `memory/ddaanet/shared-claude.md` in full.
3. Append to `CLAUDE.md` — a blank line, then as the final line:
   `@memory/ddaanet/shared-claude.md`
4. Delete from this repo's own `CLAUDE.md` any rule the shared file now
   states. Leave repo-specific rules alone: the shared file occupies the
   cross-repo scope between this `CLAUDE.md` and `~/.claude/CLAUDE.md`.
   This `CLAUDE.md` is 599 lines — the largest of the six mounting repos —
   so step 4 is real work here, not a formality.
5. Start a fresh session and confirm the shared file's contents appear in
   the `claudeMd` block. That is the only proof the import resolved.
6. Commit the parent repo — never commit inside the memory submodule.

### Specific to this repo

Two of the relocated rules bear directly on what this plugin does, and
after the import they act by default rather than needing recall: drafts go
to a file rather than inline in the reply, and no volatile git state
(commit ids, branch tips, "uncommitted as of") goes into a memory file —
a session needing exact volatile state puts it in a handoff. The second is
the load-bearing division between what `handoff` owns and what memory owns.
