# 2026-08-11 — `update-plugin-dev` collides with a consumer's `memory` submodule (v0.5.2)

Found while propagating v0.5.1 into `prohibitions`, a consumer that vendors
`plugin-dev/` and separately mounts the `ddaanet` gitlore memory tier as a
`memory` submodule at top level — the standard shape for any ddaanet plugin
repo. `just update-plugin-dev v0.5.1` died mid-fetch:

```
fatal: remote error: upload-pack: not our ref 0033b4c37eb798b57306815da656dc7c7c596ae1
Errors during submodule fetch:
	gitlore-memory
```

`git subtree pull` fetches this repo's raw, unprefixed history first — and
this repo mounts its own `memory` submodule at that same top-level path.
`fetch.recurseSubmodules=on-demand` (git's default) then tries to resolve
that gitlink using the *consumer's* registered `memory` submodule URL rather
than this repo's, since on-demand resolution keys off the path in the
consumer's own submodule config. That remote doesn't have the commit, so the
fetch fails and the pull aborts before any merge — no partial state, but no
update either. Not new in v0.5.1: a pre-existing structural issue in how
`update-plugin-dev` invokes `git subtree pull`, exposed by the first consumer
to combine both a plugin-dev vendor and a top-level `memory` submodule.

Reproduced locally with fixture toolkit and consumer repos, each mounting an
unrelated `memory` submodule at the same path, driven through `just` itself —
confirmed red against the unfixed recipe with the identical `not our ref`
failure, confirmed green after the fix. Fixed by scoping
`-c fetch.recurseSubmodules=no` to just the `subtree pull` call: a no-op for
consumers without a `memory` submodule, and harmless for consumers with one,
since the vendored `plugin-dev/memory` gitlink was never meant to be checked
out as a submodule inside a consumer anyway.

`tests/update-plugin-dev-test.sh` covers the collision going forward: a
fixture toolkit and consumer, each with their own unrelated `memory`
submodule at the same top-level path, driving the real `release.just` recipe
end to end through `just`.

See "`update-plugin-dev` disables submodule recursion for its one fetch" in
[design.md](../design.md).
