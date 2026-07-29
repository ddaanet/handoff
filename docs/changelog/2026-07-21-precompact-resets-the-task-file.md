# precompact resets the task file too (2026-07-21)

Sharing the task file ([One task file, two
transitions](2026-07-20-one-task-file-two-transitions.md)) left the two
skills on different activation protocols: handoff wiped `handoff-task.md` at
activation, precompact did not. The stated reason — a wipe would drop state
precompact carries across the compaction — does not survive contact with the
flow. precompact authors the file from the conversation, not from the file's
prior contents; nothing on disk is input to it.

What the asymmetry actually bought was a stale file surviving into precompact's
turn, where the agent is asked to write the same path. That is the shape the
wipe exists to prevent — a prior frame available to be read, extended, or
partially edited instead of replaced, and, if the flow stalls at the FR11
approval gate, a previous session's frame left behind masquerading as the
current one. "The skill writes the whole file" is an agent-compliance
guarantee; the wipe is a harness guarantee, which is the one the plugin
prefers everywhere else.

So both activation matchers now cover both skills — `precompact` /
`handoff:precompact` in the `Skill`-tool allowlist, `/handoff:precompact` in
the slash-prefix check. One protocol for the one file: invoking either skill
is unconditionally a reset.

The cost is real but small and already priced in for handoff: an abandoned
precompact leaves no task file where a stale one used to sit. That is the
honest state (nothing pending) rather than a frame from a session that has
since moved on.
