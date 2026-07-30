# precompact drives the compaction (2026-07-20)

> **Superseded 2026-07-29** (see [Driven
> transitions](2026-07-29-driven-transitions.md)) on one point: the driving
> moves to a separate skill. `precompact` no longer arms the compaction —
> it prepares and stops — and the hands-off ending this entry reversed
> returns as a *first-class* ending rather than the unconsidered caution it
> was. Everything else here carries over unchanged to `compact-continue`,
> which is where the arming now lives: memory still commits before the
> summariser runs, the flow still has exactly one interactive pause, and the
> ordering constraint on the sentinel write is unchanged in force. What made
> the split right is naming honesty, not a reversal of the intent argument —
> continuation is still intrinsic to compacting, and both skills still end
> aimed at it.

> **Superseded 2026-07-25** (see [Commit
> awareness](2026-07-25-commit-awareness.md)) on one point: the file-trigger
> IPC described below — approved message file *plus* trigger file — is now
> the **without-commit** path, taken when the request does not imply a
> commit. When it does, the agent writes the message file alone and
> gitlore's parent pre-commit hook folds the memory commit into the source
> commit. The ordering constraint at the end of this section gains a
> sibling: under with-commit the commit lands before `autocompact` is
> written, for the same reason.

precompact used to end by telling the user to run `/compact`, and was
explicitly forbidden from committing memory. Both are now inverted: the skill
commits memory through the probe's directive and arms the compaction plus the
prompt that resumes the work.

The hands-off ending was never a considered position so much as caution about
acting on the user's session. But **continuation is intrinsic to compacting**:
`/compact` summarises the context so the session can keep going. Nobody
compacts before a `/clear` — that discards what compaction just paid to
summarise — or before stopping, where there is nothing to prepare for. If the
work is ending, the tool is `handoff` + `/clear`. So invoking precompact is
already the decision to compact and continue; stopping short of it just made
the operator type two things the skill had already worked out.

The ban on committing memory rested on "compaction loses conversation state,
never disk state" — true, and it does mean the commit *could* ride any later
commit. What it misses is that the memory summary is written from the
conversation, and after compaction that conversation is a paraphrase. The
commit can wait; the material it summarises cannot. Committing before the
summariser runs is the only point where the summary is written from the real
thing.

That reframes the interactive gate too. The flow now has exactly one pause —
gitlore's FR11 per-commit approval — and only when memory is dirty. The
compact directive and continuation prompt are quality details, not
authorizations: the operator watches them typed and can interrupt. A durable
git write is the different category, and it keeps its gate.

Two consequences worth stating. The memory commit moved to gitlore's
file-trigger IPC (write an approved message file, write a trigger file, let
gitlore's `PostToolBatch` commit) — all file writes, which sidesteps the
sandbox and auto-mode classifier that made an agent-issued
`commit-memory.sh -F -` fragile, and it orders memory-before-compaction for
free, since the trigger is consumed in the same batch while the compaction
watcher only arms at turn end. And the directive text is shared with
`handoff-memory-probe`, which had been left on the older Bash path when gitlore
built the file-trigger *for* handoff; one helper realigns both.

One ordering constraint fell out of the first live run. The design assumed the
FR11 approval and the `autocompact` write could land in one turn, but an
approval is a *user response*, so asking for it ends the turn — and `Stop` is
exactly where the compaction arms. An `autocompact` written alongside the
approval request would compact away the conversation the unapproved summary is
drawn from, defeating the reason memory commits first. So the write is deferred
to the turn after the directive resolves; the skill body states this as a
condition on step 3 rather than leaving it to be rediscovered.
