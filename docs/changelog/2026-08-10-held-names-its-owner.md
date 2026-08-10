# 2026-08-10 — Held names its owner, and holds whatever types

A code review of `7525961..HEAD` returned five confirmed defects. Two were
stateful hazards around the `held` state introduced in `617505b`; the rest were
validation gaps and one latent crash. This entry records the two design changes.
The other three — a `rename` never type-checked as a string, a `precompact`
forbidden-check testing value emptiness where the `autoname` branch beside it
tests key presence, and a `jq` fold that errors on a transcript line that is
valid JSON but not an object — are fixes to code that already described the
behaviour it failed to have.

## A held sentinel outlived the session that held it

`held` was written by the checkpoint, left by `Stop`, exempted from the
`UserPromptSubmit` sweep, and left by `bin/handoff-approved` and nothing else.
The design note said a stale one was **inert**: no gate fires on that state, and
the next checkpoint call overwrites the file.

That reasoning covered every path but the one that leaves the state.
`handoff-approved` verifies the state and nothing else, so a `held` file
composed by a session that quit before approving stays armable indefinitely by
any later session in the same repo. What it then arms is that session's
`/rename` and `/clear` — into a live conversation, wiping it and submitting a
continuation prompt written for unrelated work. The exemption was reasoned from
"nothing acts on this state", but a standing command that acts on it is exactly
what the state exists to have.

The discriminator is session identity, and the sentinel carried none. Two
alternatives were weighed and dropped. **Age** — sweep a held file older than
some interval — puts an arbitrary constant where the real question is
categorical, and the approval round trip has no bound worth naming. **A sidecar
file** keyed by session id splits one fact across two files with no writer
owning both, against the one-channel-one-writer rule the checkpoint exists to
enforce.

So the owner rides on line 1: `held <session-id>`, parsed into `DRIVE_OWNER`
beside `DRIVE_STATE`. Line counts per kind are untouched, which is what keeps
the shape validation and every fixture below line 1 unchanged. `armed` and
`pending` reject an owner rather than ignoring one — they are reached only from
the session that wrote them, so a name on either describes a state nobody is
in. `handoff_drive_arm` already replaced line 1 whole, so leaving `held` drops
the owner for free, and that is the correct semantics rather than a convenience:
the owner answers *whose approval is outstanding*, and past the approval there
is none.

Both ends now check it. `handoff-approved` refuses a held file owned by another
session, naming it. `report-watcher-failure.sh` reclassifies one as abandoned
before the sweep, so it takes the same branch a stale `armed` file takes and
gets the same report — the session that would have approved it is gone, and its
answer cannot arrive at a hook running in a different session.

## The hold gated on the transition, not on the keystrokes

The state was written `held` iff the sentinel `typed` a transition *and* a
memory directive was emitted, with the comment justifying the exemption as "one
that types nothing has no such hazard".

That is false for the `rename` kind, which types. An untyped `/handoff:handoff`
is *required* to carry a title, so it composes `armed / rename / "/rename
<title>"` — and against a dirty memory submodule the same turn ends on the
approval question the memory directive asks for. `Stop` arms it and spawns the
walker, whose `is_typing` gate then races the user typing their answer: the
keystrokes interleave, or the rename submits into a pane holding a pending
approval.

The hazard was never *which* command is typed — it is keystrokes reaching that
pane at all. So the gate became the keystrokes: hold when the sentinel has any
command line and a memory directive is outstanding. Exactly one thing is exempt,
and for its own reason: the bare compact marker (FR-G), which types nothing, and
which holding would strand — the expectation it records is what
`SessionStart(compact)` gates the frame's re-injection on. `autoname` types a
`/rename` too but composes no memory directive at all, so there is no
outstanding question for its keystrokes to land on; it arms, as it did.

The `typed` flag keeps its old meaning for the `continue` field, which is a
statement about the *transition* — a continuation prompt with no transition to
submit into is still a schema error.
