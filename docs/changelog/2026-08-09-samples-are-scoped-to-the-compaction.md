# 2026-08-09 — A compaction invalidates every sample above it

Found by dogfooding, the day the transition work's third pass landed. The tool
batch immediately after a driven compaction nudged at 197354 tokens, against a
real context of 87253.

## The defect

`PostToolBatch` fires after a tool batch, but the assistant entry carrying that
call's `usage` has not reached the transcript yet. The newest sample the hook
can read is therefore the *previous* API call's.

That is not itself a bug. The prompt grows monotonically and samples arrive a
few thousand tokens apart, so measuring one call late is a rounding error
against a 150000 threshold.

A compaction is where the error stops being one. The last sample before the
boundary measures the context the compaction exists to discard, and it is the
largest of the session: the reading taken when the context was at its fullest.
After the boundary the hook attributes that number to a context an order of
magnitude fresher.

Nothing else stood in the way. The once-per-climb marker would have absorbed a
spurious second nudge, and `SessionStart(compact)` clears it — deliberately,
because a rebuilt context is where the next climb starts. The guard and the
defect fire on the same event, and the guard goes first.

So every compaction was followed by an immediate directive to compact again,
carrying a number that obeying it could not change. It survived the original
pass because the fixture transcripts are monotone: one sample, or several
sharing a message id, and nothing modelling a context that *shrinks*.

## The change

The measurement is scoped to samples newer than the last `isCompactSummary`
entry in the window. The jq fold emits a sentinel for the boundary and a number
for a usage entry, then reduces to the last number since the last boundary.

A boundary with nothing newer yields nothing, and the hook exits silent. The
alternative — falling back to the newest sample available — is the defect
restated. There is no number to report between a compaction and its first API
call, and reporting one anyway is the inference this design refuses everywhere
else.

A boundary older than the tail window needs no handling. Everything in the
window is then already newer than it, which is the answer the fold gives.

`isCompactSummary` is a structural flag, so the same rule the walker's
`transcript_prompt_count` follows applies here: key on flags, never on content.

## Tests

Three rows in `tests/hook-test.bats`, over a `compact_boundary` helper that
emits the flagged entry.

Only one of the three was red before the fix — the boundary with no newer
sample, which is the live incident exactly. The other two, a newer sample under
and over the threshold, pass under the old `last` as well: taking the newest
number is already right whenever a newer number exists. They are recorded as
regression guards rather than as evidence, and the mutation check shows it —
replacing the fold with `map(select(type=="number")) | last` reds the first row
alone and leaves both of the others green.

## Rejected alternatives

- **Have `SessionStart(compact)` leave the marker in place.** It would suppress
  the spurious nudge, and also the first genuine one after the compaction, for
  the whole life of the rebuilt context. The marker means *a nudge has been
  spent on this climb*; a compaction starts a new climb.
- **Write the boundary's byte offset into the marker file and read from
  there.** More state, and state keyed to a file two writers append to. The
  transcript already carries the boundary in-band; the hook reads the transcript
  anyway.
- **Wait or retry for the current call's entry to land.** A hook on the hot path
  of every tool batch in every session (NFR2) does not get to sleep, and the
  staleness is not the defect — the unscoped comparison is.
