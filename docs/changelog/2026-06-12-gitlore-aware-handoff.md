# gitlore-aware handoff (2026-06-12)

> **Superseded 2026-07-20** (see [precompact drives the
> compaction](2026-07-20-precompact-drives-the-compaction.md)): the commit
> path is no longer `commit-memory.sh` resolved through `git config
> gitlore.commitCommand`. The agent writes an approved message file plus a
> trigger file and gitlore's own `PostToolBatch` commits — all file writes,
> sidestepping the sandbox and the auto-mode classifier. The
> probe-as-PATH-shim rationale and the harness-over-agent split below are
> unchanged, and the directive text is now shared with the precompact probe.

The handoff skill runs a read-only probe (`bin/handoff-memory-probe` →
`scripts/memory-probe.sh`) at wrap-up; on a dirty gitlore-memory submodule
it emits a directive and the agent summarizes → gets approval → commits via
gitlore's `commit-memory.sh` (resolved through
`git config gitlore.commitCommand`). The probe is a PATH-shimmed script, not
a hook: the agent must act on the result, and verification showed
`CLAUDE_PLUGIN_ROOT` is absent from the agent's Bash while every plugin's
`bin/` is on PATH. The conditional lives entirely in the probe
(harness-over-agent); the skill body just runs it and follows its output.
gitlore's committer stays in its `scripts/` behind the self-healing
`commitCommand` key — moving it to `bin/` would reopen a shipped feature and
break the no-layout-coupling abstraction.
