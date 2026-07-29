# One task file, two transitions (2026-07-20)

precompact used to be forbidden from writing `handoff-task.md`, on the grounds
that the task crosses compaction in the summary and in the continuation prompt.
The first live run showed what that costs. The prompt written for it was
`report whether the compaction driver worked end to end … then cut the release
covering 7f3c70c..a3b9cef` — a commit range and a three-part checklist, carried
in a single line typed into a composer. It survived only because the summariser
happened to keep it too. With no durable channel available, anything
verbatim-critical gets crammed into the one channel there is.

So the file is shared. Both skills write `.claude/handoff-task.md`, and
`load-compact.sh` injects it at `SessionStart(compact)` the same way
`load-handoff.sh` does at `startup|clear` — one `handoff_frame` helper, one
frame shape. The seam is clean: the task file carries content at whatever
fidelity the work demands, and the prompt carries only a handle to it plus the
next action.

Three consequences. `handoff_activated()` now treats either skill as an
activation signal, since the read and write guards gate on it and would
otherwise deny precompact's own write — the failure would have been a mid-flow
deny, not a silent one, but it blocks the flow either way. The frame header
changed from `# Handoff` to `# Task`, because the file no longer means "a
handoff happened" but "this is the current task state". And precompact now
leaves durable cross-session state where before it left none: the file persists
after the compaction and is re-injected at the next `startup|clear`. That is
correct under the new meaning rather than a leak — it is still the current task
state — but it is a real shift, and it is why the one-sentence mandate on
`## Current task` was relaxed at the same time. That mandate was already being
violated under work pressure, harmlessly and usefully; a rule that useful
practice routinely breaks is the wrong rule.
