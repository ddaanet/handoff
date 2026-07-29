# The approval clause renders as a block (2026-07-29)

Two defects in `checkpoint_memory_directive`, both dating from
[the day before](2026-07-28-memory-approval-from-gitlore.md), when the
approval-body wording stopped being handoff's and became gitlore's.

## A borrowed string cannot be spliced into a sentence

The clause was interpolated mid-sentence — `a title line of at most 72
characters, a blank line, then a body with $clause` — which reads fine for
the one-line clause gitlore shipped that day and only for that clause. The
wording is gitlore's to change (its D19 makes it the single owner), and by
the time this was written gitlore's working tree had already replaced it
with a multi-paragraph template: a prose lead, a blank line, and an indented
`**New <tier>/<slug>:**` example block. Spliced into the middle of a
sentence, that renders as a sentence fragment stopping at a blank line with
a code block dangling off it, and then `Present it to the user…` resuming as
if nothing happened.

Nothing was broken in production yet: the installed 0.4.3 cache the config
key points at still holds the one-line version. The fix is anticipatory, and
that is the point — handoff has no say in when gitlore ships the new
template, so the directive has to be indifferent to the clause's shape. It
now goes on its own `printf` argument between blank lines. The lead sentence
drops the structure words it used to carry (`a blank line, then a body
with`): the new clause states that shape itself, so restating it is both
redundant and a second place to drift. Only the 72-character limit stays
behind, because it is handoff's constraint and the clause never mentions it.

The test fixture was why the suite could not see any of this. A single-line
`GITLORE_MEMORY_APPROVAL_CLAUSE` makes "rendered as a block" and "spliced
into a sentence" indistinguishable, and `grep -qF` over a multi-line pattern
does not test what it looks like it tests — it matches any one line of it.
The fixture is now multi-line and shaped after the real template, and the
assertion is bash substring matching for contiguity plus blank-line framing
for blockness. The framing assertion is red against the old code and green
against the new, which is the mutation check.

## A missing key is not a missing plugin

The other branch — key unset, or pointing at a file that is not there —
reported that "the gitlore plugin looks disabled or not installed for this
session" and told the user to check `/plugin`. That misdiagnoses. gitlore
pins the key at every `SessionStart`, at a path stamped with its own
version, so the overwhelmingly likely cause is a gitlore that updated and
has not had a `SessionStart` since: installed, enabled, working, and the
pinned path simply moved out from under a session that started before it.
`/plugin` does nothing for that.

The replacement states one fact and one act: the key is unset or its file is
missing, gitlore pins it at `SessionStart`, restart Claude Code and retry.
An earlier draft enumerated the causes — installed-before-this-session
versus updated-since, the version-stamped path — and kept `/plugin` as a
fallback. That was cut: gitlore and handoff are both maintained here, the
transition window for any given move is one restart, and a branch that
exists only to narrate a transition outlives it and is wrong afterwards.
The single `SessionStart` clause survives only because "restart" reads as
arbitrary without it.

The early return is unchanged, and so is the reason for it: blocks 2a/2b
never fire without a resolved clause, so a broken discovery path still fails
loud rather than silently dropping the FR11 approval gate on handoff's side.
