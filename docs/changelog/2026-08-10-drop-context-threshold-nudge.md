# 2026-08-10 — Drop the context-size nudge

## The decision

The context-size nudge — `PostToolBatch` measuring this session's prompt and
injecting a directive to run `/handoff:precompact` past 150k tokens — is
removed outright, not tuned. `scripts/context-threshold.sh` is deleted, along
with its `hooks.json` wiring, `_lib.sh`'s `handoff_context_path()`, and
`session-pointer.sh`'s re-arm of the marker it wrote.

## Why a fix wasn't enough

Two problems, neither of which a threshold adjustment resolves:

- **It fired too early relative to what the prompt actually needed.** A
  session can carry a large prompt for reasons the token count alone doesn't
  distinguish from bloat — deep exploration mid-task, a long but coherent
  investigation. The nudge couldn't tell "large and about to become
  unproductive" from "large and still fine," so it fired on both.
- **It fired once right after a driven compaction.** [The 2026-08-09
  fix](2026-08-09-samples-are-scoped-to-the-compaction.md) addressed the
  specific defect — a stale pre-compaction sample read as the post-compaction
  context — and held up under its own tests. The live incident it fixed was
  still evidence that the mechanism could misfire in ways a threshold number
  can't anticipate.

Compounding both: reported by my human partner from direct observation, the
nudge was sometimes followed and sometimes ignored, with no way to tell from
the marker alone which had happened. A directive that is inconsistently acted
on is worse than either a hard boundary or no nudge at all — it trains
neither the agent nor the reviewing human to trust it.

Non-Haiku windows are 1M and `autoCompactEnabled` is expected off (the
original premise, still true): there is no wall to race, only a preference
about context quality and cost. That preference no longer justifies the
false-positive rate.

## What stays

`/handoff:precompact` itself is untouched — it remains fully usable on
request, driven or not. Only the automatic trigger is gone; a session now
compacts when the agent or the user decides to, not when a `usage` sample
crosses a fixed number.

`session-pointer.sh` keeps sweeping `handoff-root-*` and `handoff-drift-*`;
only the `handoff-context-*` marker and its re-arm are gone. The `find`
sweep's filter drops back to two names.

## Superseded

[Nudge the boundary at a context-size
threshold](2026-08-01-context-threshold-trigger.md) and [A compaction
invalidates every sample above
it](2026-08-09-samples-are-scoped-to-the-compaction.md) describe a mechanism
that no longer exists. Both carry a `Superseded` marker pointing here rather
than being rewritten — they remain the accurate record of what was tried and
why, at the time.
