# Task frame drops the transcript and file list (2026-07-17)

The frame is a timestamp header plus the inlined agent-authored task
file. `load-handoff.sh` reads nothing but that file. The `## Files
touched` and `## Last user prompts` sections, the transcript scrape, and
the whole machinery that fed it are gone.

## The injection manufactured false continuity

A session where the injection actually fooled the reader: a fresh
session opened at ~61k context, clean tree, having done nothing; on the
first prompt ("Continue") it asserted "this session's context is spent
on the splits" — narrating a *prior* session's work as its own.

The injected transcript reproduced prior exchanges verbatim, in
conversational grammar (agent voice, user voice, turn after turn). That
does not read as *a report about a past session* — it reads as
**memory**. There is no felt boundary between "what I did" and "a
transcript of what someone did in my voice"; both arrive as the same
kind of text, so a faithful transcript overwrites the actual short
session with a fabricated long one, and "Continue" demands a
continuation the transcript stands ready to fake. The hazard scales
with volume: one exchange is a seam; five prior exchanges are a fake
episode you start living inside.

The two irreducible fields — **Current task** and **Open decisions** —
already live in the task file, in report register; that file is the
"where we left off" seam. The verbatim transcript was a second capture
of the same ground, in the one register that does the harm. A shorter
transcript is no cure: trimming changes length, not register. The only
genuinely-uncaptured content is the tail *after* the task-file write,
but the handoff skill writes that file as its last action, so the tail
is structurally empty — non-empty only when the user works past handoff
and `/clear`s without re-running it, a misuse whose honest signal is
"nothing pending — re-run handoff." So the transcript goes whole.

## The file list presented durable state as live

The honest capture boundary for files is the **commit**, not the
task-file write. Committed files are done, in git — yet
`## Files touched`, spanning the whole session, made them look
in-flight; in the origin session the listed files were committed and
the list contradicted the harness's own `Status: (clean)` in the same
context window.

The harness injects a live `gitStatus` block at SessionStart, current
as of the successor's start — after the prior session's commits landed.
It dominates any snapshot the handoff could embed and dissolves the
"which subset" question (touched-since-write? uncommitted? the
intersection drops files left dirty before the write). Deferring to it
is safe even where `gitStatus` is absent: the fallback is an empty
working set, which is the truth — "nothing is pending; you have not
done anything yet." The old list degraded that honest empty state into
committed files that kept whispering continuity.

## No session id, no pointer chain

Once nothing reads the transcript, the entire read-time pointer chain is
vestigial — its sole job was handing the prior transcript to
`extract.py`. It comes out in one pass: the `.claude/handoff-session`
pointer, the `extract.py` subprocess (frame assembly collapses into
`load-handoff.sh` — a `date` header and a `cat` of the task file), the
`handoff-error.log` sink that only `extract.py` could fill, and the
`Session: <id>` line the id fed. The header's timestamp already dates
the frame; the session id only ever named a transcript nothing opens.
`write-stage.sh` keeps just its `git add -f`. A design that proved
harmful is removed whole, not left as a scaffold guarding its return.
