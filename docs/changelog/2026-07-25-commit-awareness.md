# Commit awareness (2026-07-25)

The routine wrap-up is `/handoff` then `/commit`. Handoff's memory step always
took gitlore's standalone path — write the approved summary *and* the trigger,
let `PostToolBatch` commit the submodule on the spot.

**This is not a history defect, and the first draft of this section said it
was.** The standalone commit is a commit in the *submodule*. The parent's
pre-commit hook stages the moved gitlink unconditionally
(`scripts/git-hooks/pre-commit:75-91`, whether or not the sync it just ran
moved anything), so the next parent commit records the source change and the
pointer bump together regardless of which path ran. Both paths end with one
parent commit and one memory commit, pointing at each other identically.
`feedback_bundle_memory_with_source` is about *parent* commits — one carrying
both, not two — and neither path violates it.

What the standalone path actually costs is a round trip. It needs two file
writes, and they are free only if the agent issues them in one tool batch.
Measured over every transcript that writes either IPC file, grouped by
assistant `message.id` (Claude Code splits one message across several JSONL
entries, so per-entry counting reads every write as unbatched): of 65 IPC
writes inside a handoff or precompact activation, 28 batched both files into
one message and 37 split them across two — 43% batched, 39% excluding
gitlore's own development sessions. A split costs one extra API round trip,
median 5.9 s (quartiles 4.9 / 5.9 / 8.6). So the second file is a wasted round
trip 57% of the time, and buys nothing the bundled path does not already give.

The mechanism already existed on gitlore's side. Its parent pre-commit hook
commits memory whenever it finds a fresh approved summary, and the trigger file
is the *only* thing that makes `PostToolBatch` commit standalone. So the whole
difference is one file: summary alone defers, summary plus trigger commits now.
Freshness is an mtime comparison against the newest file in the memory
worktree, which makes "write the summary last" a real constraint rather than
style — a memory edit after it stales the summary and aborts the parent commit.

Because the difference is one *filename*, withholding it is the mechanism. The
with-commit directive does not mention `.claude/gitlore-commit-memory`, nor the
idea of a trigger at all: its reader is a fresh agent in an arbitrary project,
with no memory of a previous session and no maintainer documentation, so that
path has no other source and the standalone commit is simply unreachable. The
approved design had it the other way — name the trigger, forbid it explicitly —
reasoning that an agent who knows the two-file protocol needs it forbidden
rather than omitted. Two things are wrong with that. The agent who knows it is
the rare case, and the prohibition hands the common case the one string it was
missing. And a prohibition is not free: it introduces the concept, and an
introduced concept gets reasoned about.

The same cut applies to everything else the directive was carrying. An earlier
draft explained the pre-commit hook, the gitlink staging, and gitlore's mtime
freshness rule. None of it is actionable — the agent's entire contribution is
to write one file — and mechanism a reader cannot act on does not sit inert: it
gets verified, narrated back to the user, and worked around.

The freshness rule is the interesting cut, because it *is* a real constraint. A
memory edit after the summary write aborts the parent commit. But it is an
ordering between the skill's own steps, and both skills finish memory before
they run the probe — so a directive saying "only after every memory edit is
final" reaches a reader who has already complied, and asks a question whose
only possible answer is narration. Nor does it move to a skill body: "once
approved" already places the summary write after the memory edits, and approval
is the end of a feedback loop rather than the start of one — the user may well
ask for a memory change there, which is what review is for. An intermediate
draft did state it as a skill-body rule ("memory is final at its memory step"),
which forbids the thing the gate exists to enable; if an edit does land after
the summary write, gitlore's abort says so at the point where that is
actionable. What is left in the directive is one act plus one clause
saying the commit that lands the change carries the memory, which exists only
so the absence
of a commit is not read as a failure worth recovering from. The load-bearing
test is the corresponding negative, mutation-checked.

A second, smaller defect rides along, and it is the reason this is a skill-body
concern and not only a probe branch. When a commit is part of the request, the
snapshot is written *before* it lands, so anything phrased as pending — a
memory body describing a change as proposed, a `handoff-todo.md` item saying
"commit the work" — is false the second the user commits, and gets re-injected
that way at the next session start. Only the memory half is new guidance.
Commit/push status in the task file was already an anti-pattern, and an
unconditional one; a mode-scoped restatement of it would imply the item is
acceptable under `without-commit`, so handoff's step 1 leaves that half to the
anti-pattern list and speaks only about memory bodies. precompact's step 1 kept
the `handoff-todo.md` form of it until the re-phrasing below took its condition
away; the anti-pattern now covers both files, and both step 1s say the same
thing.

**The agent supplies one fact; the code owns the branch.** Both probes take a
required positional argument, `with-commit` or `without-commit`, answering
*"is a commit going to carry this session's memory?"* — which is a fact about
the conversation and the tree, not something a script can see. Everything
downstream of that answer is
deterministic. Detecting it in the probe was rejected twice over: a transcript
scrape is the maintenance trap this design already refuses for the todo list,
and a slash-command name is not the question. Defaulting the argument was
rejected too: a default is the answer given by an agent that has not thought
about the question, and thinking about it is the entire contribution. The two
values are peers, validated by a shared `probe_require_mode` that sets a global
rather than printing — `exit 2` inside a command substitution ends only the
subshell, and the caller would sail on with an empty mode.

The question was first phrased as *does this request imply a commit?*, and
dogfooding broke that phrasing on the first divergent case: a precompact run
with no commit anywhere in the request, whose memory documented the very
implementation sitting uncommitted in the tree. That case has to answer
`with-commit` to route the memory correctly and `without-commit` to answer the
question as written, and the agent silently resolved it by routing and ignoring
the rest. The flag was carrying two conditions that coincide in both routine
cases — which files the probe names, keyed on whether a commit carries the
memory; and how the snapshot is tensed, keyed on whether that commit lands
before the snapshot is read again. Neither failure is expensive, and an earlier
version of this paragraph claimed routing was: answering `without-commit` when a
commit is coming costs the wasted round trip above, answering `with-commit` when
none is leaves memory uncommitted behind an approved summary until some later
commit collects it. The binary asks the routing question because that is the
half the probe branches on — the tense half needs no mode, since present-tense
truth is the standing rule whenever the change exists in the tree. It stays a
binary: a third value would branch identically in the probe and only rename a
shade of prose. The two rules that genuinely needed *this request* now carry that
condition themselves: precompact's commit-before-`autocompact` ordering states
it, and the `handoff-todo.md` half joined the anti-pattern that already held the
task-file half unconditionally.

Where each half of the guidance lives is forced by *when it is read*, the
same constraint as [A directive must fit where in the turn it
lands](2026-07-22-directive-fits-where-it-lands.md) (2026-07-22). handoff
runs its probe in the same turn as the writes, so a directive about how to
write them arrives after they exist. The skill body is read before step 1.
So the memory branch — read at the moment it acts — stays in the probe, and
the decision plus the write-as-landed rules go in both skill bodies, where
they are read in time to change what gets written. Emitting the
write-as-landed guidance from the probe would have been correct for
precompact and a no-op for handoff.

precompact carries one extra rule, and it is load-bearing: when the commit is
part of the request, it lands **before** `./.claude/autocompact` is written.
Arming the
compaction ends the turn at `Stop`, so an autocompact written first means the
compaction runs instead of the commit. Same shape as the existing "never in the
same turn as a question the directive requires", and stated as such.

Committing is not one of either skill's steps, and neither skill says so. An
earlier draft did — "this skill never commits" — plus anti-patterns against
defaulting the answer and against running git under `with-commit`. All three
came out. "handoff and commit" is the ordinary request in this mode, so a line
reading as *do not run git* refuses the thing that was asked for; and the two
anti-patterns described defects nobody had seen, in lists that otherwise record
ones that happened. The only ordering that matters is precompact's, and step 5
states it positively. gitlore's FR11 approval remains the flow's one gate.

The approved summary *is* the memory commit's message — gitlore feeds the file
to `git commit -F` verbatim, in the submodule and in each tier — so the
directive asks for the shape of one: a title line of at most 72 characters, a
blank line, then a body of one bullet per memory file. The earlier "1-3
sentences" produced a paragraph where git's conventions want a subject line, and
it landed in history that way. This is preamble text, shared by both modes and
both probes, and it also changes what the approval gate shows: the user reviews
the commit message itself rather than a prose gloss on it.
