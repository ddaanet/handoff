# A place for the todo list (2026-07-22)

`handoff-task.md` was being used to carry full task lists, and the same
items were tracked again in gitlore memory — so completing one task meant
editing several places, each with an approval-gated commit. The fix is not
another prohibition. It is a file: `.claude/handoff-todo.md`, holding the
**remainder** of an active task list and nothing else.

## Memory is not the place, and says so

The memory harness has no todo affordance at all, and the silence is
structural. A memory is "one file holding one fact"; a task list is N items
plus a mutating completion state. The four types are user / feedback /
project / reference, and the nearest — `project` — is scoped to work
"not derivable from the code or git history", which a todo list is: its done
half *is* git history. The exclusions name it twice over ("what the repo
already records… or what only matters to this conversation").

The cost of ignoring that is measurable in this repo. `project_precompact_drive.md`
took five commits in three days, four of which changed nothing but completion
state — shipped-but-unreleased → released → also v0.10.1 → fixed → shipped in
v0.10.2. A status line is a task list of one, and it has to be re-approved
every time the work moves.

## Reconstructable is two categories, not one

The residual analysis drops reconstructable state — git status, files
touched — and that rule, applied flatly, would drop a todo list too. It
shouldn't, because those are reconstructed by the **harness**:
deterministically, free, at read time, correct by construction. A todo list
after a compaction is reconstructed by the **model**, from a paraphrase, with
real error probability, and it fails silently by redoing finished work.

So the test splits. Reconstructable-by-machine → drop it, defer to the
harness. Reconstructable-only-by-inference → carry it, because the inference
is avoidable and its failure is invisible. The undone half of a task list is
a decomposition, which is judgment; it clears the residual bar that the done
half does not.

## The design names no tool

`TodoWrite` was superseded, not removed. In Claude Code 2.1.217 the string
survives 13 times with **no tool definition** — a bare constant, membership in
timeout/permission name-sets, the stale nag copy, and a scan that reads
historical `TodoWrite` entries out of old transcripts. The replacement is a
task-list family (`TaskCreate`/`TaskGet`/`TaskList`/`TaskUpdate`),
`shouldDefer: true`, gated `isEnabled(){ return bL() && !TZ() }` — where `bL()`
is on unless `CLAUDE_CODE_ENABLE_TASKS=false` and `TZ()` is a server-side
killswitch matching a `tengu_vellum_ash` gate list. Neither family was
reachable in the session where this was designed, with the flag unset locally
and nothing in any changelog.

An affordance that can vanish between two sessions on the same binary cannot
be a dependency. So the framing inverts: **the file is the ledger, whatever
tracker is live is a cache.** Nothing in the skill body names a tool; the
remainder is injected as content, and an agent with a tracker may load it in,
which is its own business. The cache may legitimately hold more than the
ledger — item identity, ordering, per-item history — because that surplus is
boundary-local, the same way the task file declines to duplicate `git status`.

Identity loss across the ledger is therefore not a cost to price. At `/clear`
nothing survives but files, so the remainder is an accurate account of what
crosses; at `/compact` the session continues and a tracker survives on its
own. The operator's choice of boundary is the lever.

## It rides the existing frame

The remainder is injected by `handoff_frame`, next to `## Current task`, at
both transitions. No new hook, no directive, no latch.

First-`UserPromptSubmit` was considered, to put a new user task ahead of the
injected list. The hazard is real and documented — [Task frame drops the
transcript and file list](2026-07-17-task-frame-drops-transcript.md) records
a session that read injected content as its own memory. But the fix that
worked there was **register and volume**, not position: the report-register
task file still injects at SessionStart and has not reproduced it. A
remainder list is on the safe side of that line. Position is a weak lever
anyway (recency argues the opposite way), explicit conditional wording is
the strong one, and "first UPS" needs the once-per-session latch this design
rejected as an armed/disarmed marker — on a per-turn hook.

## The skill body decides, not a probe

No script can see the agent's list: there is no todo store on disk here, and
scraping the transcript means keying on a tool name. Claude Code's own nag
does exactly that (`tool_use` with `name === "TodoWrite"`, plus an
`attachment.type === "todo_reminder"`) and now reads a dead string — the
maintenance trap the JSONL-coupling stance already warns about. The agent
knows its own list for free and cannot rot, and a probe branch would cost the
single-parallel-turn requirement a detection round-trip.

The probes keep the one question a script *can* answer: whether a foreign
workflow ledger exists. `probe_ledger_path` is the registry; when it hits,
`handoff-todo.md` stands down, so an SDD session tracks in one place. Both
probes compose it — a ledger outlives a `/clear` exactly as it outlives a
compaction — with precompact folding the suppression into its
bring-the-ledger-current nudge and handoff emitting it alone.

## Both skills write it; it is wiped; it is not tracked

> **Superseded 2026-07-23** (see [Overflow deserves the same
> persistence](2026-07-23-overflow-deserves-persistence.md)): the
> gitignored-not-tracked paragraph below is reversed; `write-stage.sh`
> force-adds the todo file exactly as it does the task file. Everything else
> in this section stands.

precompact writes it too, and the reason is *not* the one that justifies its
task-file write. A tracker-backed list would survive compaction untouched —
but with no tracker the list is context-resident, and context is exactly what
compaction paraphrases. Writing before the summariser runs is what spares the
successor an inference it would make wrong and silently.

It is wiped at activation despite being input carried forward, because both
loaders put it back in front of the agent at SessionStart — so re-authoring is
from context, never from the file — and because without the wipe a finished
list lingers on disk forever, re-injecting done items as outstanding. The
alternative, an agent-issued delete when the list empties, is mechanical work
the harness should do.

It is **gitignored**, and that is the one place it departs from the task file.
`handoff-task.md` is tracked because it pairs with a gitlore memory commit as
an in-history record; a remainder has no such pairing, and a tracked checklist
would reintroduce the churn at boundary cadence. Snapshot versus ledger: the
task file is a frozen account of a moment worth versioning, the todo file is
working state carried forward.

The guards cover it on the same terms as the task file — the defect that
motivated them was the agent co-opting a handoff file as a scratch todo list
before any skill ran, which shipping a real todo file would reopen. Guarding a
second path made `handoff_match_target` variadic over (basename, rel) pairs:
the JSON parse is a jq spawn on the Write/Edit hot path, so N files must stay
one parse.
