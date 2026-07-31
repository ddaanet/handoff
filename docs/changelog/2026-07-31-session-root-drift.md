# 2026-07-31 — The session root stops drifting silently

The full write-time record, including the transcript evidence and the
alternatives weighed, is
[`plans/2026-07-31-session-root-drift-design.md`](../../plans/2026-07-31-session-root-drift-design.md).
This entry is what changed and why.

## The defect

A session launched in `gitlore` moved its cwd to `handoff` mid-session and
stayed there. Everything derived from **cwd** switched at that instant — the
environment block's working directory, the `gitStatus` block, the project
`CLAUDE.md`. Everything derived from **launch** did not — the transcript
directory, the scratchpad, `CLAUDE_PROJECT_DIR`. Nothing announced it. The
agent reasoned from the pre-flip repo for four turns; it took the user asking
"what project are you in?" to surface it.

The root policy was not the fault. `handoff_root` returned `gitlore`, which is
correct: the launch repo is where the thread lives, and following cwd would let
one session leave two `.claude/` states behind, the second belonging to no
thread. Two other things were:

1. **The resolver could not say which branch it took.** Four different
   situations — cwd inside the project, cwd a foreign repo, cwd a linked
   worktree of some *other* project, cwd in no repo at all — all collapsed to a
   bare `project` on the way out. No caller could tell drift from the ordinary
   case, so no caller could report it.

2. **`handoff-checkpoint` could not see `CLAUDE_PROJECT_DIR` at all.** It runs
   in the agent's Bash, where the variable is unset, so `handoff_root` fell
   back to `$PWD` — the drifted cwd. The writer reached a different root than
   every reader. Observed: the checkpoint wrote and staged *handoff's* task
   file while the `/clear` that followed would have injected *gitlore's*, a
   frame from an unrelated thread. It also overwrote handoff's own in-flight
   task file with content meant for gitlore, and staged the overwrite in the
   same act.

## What changed

**`worktree_root.py` labels its branches** — `inside`, `worktree`, `foreign`,
`unrelated` — and prints the label on a second line. `handoff_root_read` sets
the caller's `HANDOFF_ROOT`/`HANDOFF_ROOT_BRANCH` (the `handoff_drive_read`
idiom); `handoff_root` stays what it was, the root alone on stdout, since every
other caller captures it in a `$(...)` where a global would die with the
subshell. The bash fast path labels the branch itself, or a caller would read
whatever the previous resolution left behind. Detection costs nothing: the fast
path already short-circuits the two non-drift cases without spawning, and every
remaining call already spawned `python3`.

Containment beats the branch the walk took: a submodule or a vendored checkout
*inside* the project is reached by the same `.git`-is-a-file/-directory branches
a foreign repo is, so `cd memory/` would otherwise report drift every turn.

**A session-keyed pointer file bridges into the agent's Bash.** One line, the
resolved root, at `/tmp/claude/handoff-root-<session_id>`, written by a new
`SessionStart` hook (`session-pointer.sh`) on a wildcard matcher. Not a
preference about where handoff state lives — it is the bootstrap. The
checkpoint cannot read a file at the project root, because addressing that path
is the very thing it cannot do, so the pointer goes where both sides can
address blind. The directory is a literal rather than `$TMPDIR`: the producer
is a hook, the consumer the agent's sandboxed Bash, and the two share no
environment but the session id.

Its own script rather than a preamble on the two loaders, because the write
must be unconditional and both of those are gated — `load-handoff.sh` on the
task file, `load-compact.sh` on `.pending`. The wildcard matcher also reaches
`resume`, which the previous table (`startup|clear`, `compact`) did not cover
at all.

**The checkpoint reads the pointer and refuses without it.** A live session
always has one, so its absence is abnormal: exit non-zero naming the path,
rather than falling back to `$PWD`, which was the old behaviour and is silently
wrong in exactly the drift case.

**Drift is reported at observation, from `UserPromptSubmit`.** Not at some
later gate: drift can be transient — one session showed 22 consecutive entries
in another repo across four exchanges, then reverted — and a check that asks
"is cwd foreign *now*?" afterwards sees nothing, while the writer/reader split
was live for the whole blip. `report-watcher-failure.sh` already resolves the
root every turn and already owns a reporting channel, so the check rides there.
One report per episode: a marker holds the destination last announced, so a
second turn in the same place is silent, a move somewhere else is not
swallowed, and returning clears the marker so a re-drift is a new episode. The
`systemMessage` leads with an ANSI style reset — this hook speaks only when
something went wrong, and the chatter it sits among renders dimmed.

## Rejected

- *Following cwd.* Two `.claude/` states per session, the second orphaned.
- *Naming the root in `load-handoff.sh`'s `additionalContext`* and having the
  skill pass it in the payload. Free, and it survives compaction — but it puts
  a hand-copied path in the agent's hands, which is the judgement/mechanism
  split the plugin draws against.
- *Letting `bash-post.sh` validate or relocate after the fact.* It is the one
  component that both has `CLAUDE_PROJECT_DIR` and sees the checkpoint — but it
  fires after the write, so it could only report a file already written to the
  wrong repo, and staged in the same act.
- *Caching the resolver's verdict in the pointer* to spare the per-turn
  `python3` spawn a drifted session incurs. It made a file written once at
  `SessionStart` responsible for a value that depends on a cwd which moves — an
  optimisation of a state that should be rare and loud.

## Believed at the time, unverified

That a hook payload's `session_id` carries the same id as
`CLAUDE_CODE_SESSION_ID` in the agent's Bash. The variable is the harness's own
session id — it matches the id embedded in the scratchpad path and the
transcript filename — but the hook-payload half rests on nothing measured. A
wrong answer is caught loudly rather than silently: the checkpoint finds no
pointer and refuses. First dogfood settles it.

That `systemMessage` honours ANSI at all. If it does not, the reset renders as
literal bytes at the head of the line and comes back out.

## Left open

- **`write-guard.sh` rc 2.** Under drift, a legitimate agent edit to the cwd
  repo's `handoff-todo.md` resolves outside `$root/.claude/` and is denied as
  cross-project, with no mention of the drift that caused it.
- **Lifecycle.** Nothing removes `handoff-root-<session_id>` or
  `handoff-drift-<session_id>`, and `/tmp/claude` is not swept. One short line
  per session.
