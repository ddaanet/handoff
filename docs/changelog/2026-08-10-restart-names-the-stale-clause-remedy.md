# The stale-clause diagnosis names /handoff:restart, not a three-way split (2026-08-10)

`brief-driven-restart.md` asked `handoff-checkpoint`'s gitlore diagnosis to
split into "gitlore not installed here / key never set / key points at a
path that no longer exists," quoting the diagnosis as "the gitlore plugin
looks disabled or not installed for this session… Check `/plugin`."

That quote was already stale by the time the brief was written two days
later. [2026-07-29](2026-07-29-approval-clause-renders-as-a-block.md) had
already replaced it, and had already considered and rejected exactly the
split the brief re-asks for: "An earlier draft enumerated the causes —
installed-before-this-session versus updated-since, the version-stamped
path — and kept `/plugin` as a fallback. That was cut: … a branch that
exists only to narrate a transition outlives it and is wrong afterwards."
The brief's quoted text is what a stale *cached* plugin install was still
showing — a session running an old handoff build, the very failure mode the
brief itself is about — not what the repo's own `HEAD` said. The reasoning
against splitting still holds: unset-key and missing-file are both symptoms
of the same transition window (a `SessionStart` that hasn't re-pinned the
key yet), the remedy is identical either way, and a message that names the
sub-cause narrates a fact the reader can't act on differently.

What was still outstanding: the remedy line said "restart Claude Code and
retry" when the brief was written, before the `restart` transition kind
existed. It now names `/handoff:restart` directly (with the manual
exit-and-`--resume` form kept alongside, since the skill is invoked by
request — see the restart skill's own anti-pattern against treating a
notice as license to restart unprompted).

An implementation pass first split the message by cause before this
history surfaced; reverted before landing, the split test doubled as the
confirmation that the two causes now report identically once more (`git
config … is unset` and `… points at a missing file` collapse to the same
`_printf_lines` call).
