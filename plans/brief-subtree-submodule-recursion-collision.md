## Brief: `update-plugin-dev`'s subtree pull collides with a consumer's gitlore `memory` submodule

2026-08-11

### Decisions

- Root-caused and reproduced in `prohibitions` (a consumer plugin) while
  running `just update-plugin-dev v0.5.1` (upgrading from v0.5.0). Not
  something that changed in v0.5.1 — a pre-existing structural issue in how
  the recipe invokes `git subtree pull`.
- Interim workaround, verified working: wrap the consumer's invocation with
  `git config fetch.recurseSubmodules no` before, `git config --unset
  fetch.recurseSubmodules` after. This is per-consumer and undocumented, so
  it doesn't scale — the real fix belongs in this repo's recipe.

### Constraints

- Any fix must be a no-op for consumers that don't mount a `memory`
  submodule (most consumers today).
- This repo is read-only from the session that filed this brief — the fix
  needs to land here directly, not be proposed as a diff from outside.

### Rejected approaches

- None evaluated beyond the manual `git config` workaround above — it
  proves the diagnosis and unblocks one consumer, but isn't a fix.

### Additional context

**Reproduction.** `prohibitions` vendors `plugin-dev/` via subtree and
separately mounts the `ddaanet` shared memory tier via gitlore as a
submodule at top-level path `memory` (`.gitmodules`: `path = memory`, `url
= git@github.com:ddaanet/prohibitions-memory.git`). Running `just
update-plugin-dev v0.5.1` failed:

```
From github.com:ddaanet/claude-plugin-dev
 * tag               v0.5.1     -> FETCH_HEAD
Fetching submodule memory
fatal: remote error: upload-pack: not our ref 0033b4c37eb798b57306815da656dc7c7c596ae1
Errors during submodule fetch:
	gitlore-memory
```

The pull aborted cleanly before any merge — no partial state to recover.

**Mechanism.** `release.just:69`'s `update-plugin-dev` recipe runs:

```
git subtree pull --prefix="{{toolkit_prefix}}" "{{toolkit_url}}" "{{ref}}" --squash
```

`git subtree pull` fetches the *raw, unprefixed* history of this repo
(`claude-plugin-dev`) first, via an ordinary `git fetch <url> <ref>`. This
repo itself mounts gitlore memory as a submodule at top-level path `memory`
— so the fetched history contains a gitlink at path `memory` pointing at a
commit on *this repo's* `gitlore-memory` remote.

Git's default `fetch.recurseSubmodules=on-demand` then kicks in: it sees
that path `memory` changed and that the *consumer* repo also has a
submodule registered at that same path — so it tries to fetch the
referenced commit using the **consumer's** registered submodule URL
(`prohibitions-memory.git`), not this repo's `gitlore-memory` remote. That
remote doesn't have the commit, hence "not our ref."

This will hit **every consumer that both vendors `plugin-dev/` and mounts a
gitlore `memory` submodule at the top level** — not specific to
`prohibitions`. Any ddaanet plugin repo following the standard gitlore
mount convention is exposed.

**Suggested fix.** Scope the override to just this one fetch, inside the
recipe itself, so no consumer needs to know the workaround:

```
git -c fetch.recurseSubmodules=no subtree pull --prefix="{{toolkit_prefix}}" "{{toolkit_url}}" "{{ref}}" --squash
```

**Suggested regression coverage.** `just precommit`'s `_import-check`
already exercises `release.just` against a stub consumer — a similar stub
with its own `memory` submodule at the same path (pointing anywhere, even a
throwaway local repo) would reproduce this collision and catch a
regression.
