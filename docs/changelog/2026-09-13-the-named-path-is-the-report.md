# The named path is the report — 2026-09-13

`bash-post.sh` carried a comment asserting that "git's stderr now reaches the
user". Nothing in the tree demonstrated it. The bats row it was leaning on
(`tests/checkpoint.bats`, the stranded-`index.lock` case) greps git's message
out of a file the test itself redirects the hook's stderr into, which proves
the message reaches the *process's* stderr and says nothing about who reads it.
The claim mattered because it set how much the failure branch had to say: if
git explains the failure to the user by itself, naming the path is a
convenience; if it does not, the named path is the entire report and the
wording carries the whole burden.

## What a PostToolUse hook's stderr actually does

Probed against CC 2.1.270 — a scratch `--settings` PostToolUse hook under a
nested `claude --print --output-format stream-json --verbose`, emitting a
distinct marker on each of the three channels and exiting 0. Of the three:

- `systemMessage` arrives as `type: "system"`, `subtype: "informational"`,
  rendered `PostToolUse:Bash says: …`. The user-visible channel.
- `additionalContext` arrives as a `type: "attachment"` transcript entry whose
  `attachment.type` is `hook_additional_context`, carrying a `rendered`
  `<system-reminder>`. The agent-visible channel.
- **stderr** appears only inside a *separate* attachment, `hook_success`,
  alongside `stdout`, `exitCode`, `command` and `durationMs`. That entry has no
  `rendered` field. It is echoed to no one and injected into nothing; it never
  appears in the `--verbose` event stream, and it does not reach the hook
  process's parent either.

So on `exit 0` — which a hook that wants its stdout JSON parsed has no choice
but to take — stderr is a transcript record, not a channel. The comment is now
downgraded to what is demonstrated, and the design's claim about the failure
branch rests on the named path alone.

Two consequences follow, and both are changes rather than rewordings.

## The remedy rides the agent channel

The manifest is consumed unconditionally, so a failed `git add` costs the
staging outright: retrying inside the hook would re-run the same command
against the same stranded lock, and nothing downstream stages these two
gitignored paths. The agent-facing sentence named the path and stopped there —
a fact with no act attached, at the one audience that could perform one.

It now ends `— stage with git add -f before the next commit`, and the
user-facing summary deliberately does not. An instruction rendered beside every
staging failure is noise for the human and no better targeted for the agent,
which reads its own channel either way.

## A root that is no repository is not a failure

The per-path failure branch was written for defects: a stranded `index.lock`, a
corrupt index. A handoff root that is not a git repository is neither. Nothing
can be staged there, nothing is wrong with the checkpoint that wrote the
manifest, and the old code discovered this once per manifest line — reporting a
single environmental fact twice, in the wording reserved for breakage, and
(after the change above) with a remedy naming a repository that does not exist.

`git rev-parse --git-dir` now separates that whole-run case ahead of the loop.
It reports once, on both channels, saying what is true — the task and todo
files are written, and only staging them needs a repository — and consumes the
manifest, since there is no staging to preserve and a later checkpoint composes
a fresh one.

That guard keeps a `2>/dev/null`, the only one left in the file. It is the
third case of the standing rule rather than an exception to it: provoking
`fatal: not a git repository` *is* the check's mechanism, and the branch it
opens is what speaks for that message. The reason is written inline.

## What this cost the test suite

The `D whose index cannot be read` row used a garbage `.git` file as its
fixture, chosen so that an enclosing repository could not rescue the failure
into a successful, empty `ls-files`. That fixture is now the whole-run case,
which the new guard takes first. It is repointed at a real repository whose
*index* is garbage: `rev-parse --git-dir` succeeds, `ls-files` fails, and the
row tests the branch it names again. The same reasoning repaired the worktree
row, whose fixture was a `gitdir:` pointer into a directory git could not
resolve; it now carries the `commondir`/`gitdir`/`HEAD` trio, so the row keeps
testing root resolution instead of falling into the new branch.

Two rows are added — the whole-run case, which every other `bash-post` row
`git init`s past, and the remedy clause's channel asymmetry — and both are
mutation-checked: deleting the guard reds the first alone, and removing the
remedy clause reds the two rows that pin it and nothing else.
