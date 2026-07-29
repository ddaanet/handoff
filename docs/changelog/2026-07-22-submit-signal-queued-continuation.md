# The submit signal, again: is_busy false-fails a queued continuation (2026-07-22)

The prior section ([The settle gap and the submit
signal](2026-07-20-settle-gap-and-submit-signal.md)) moved line-2
confirmation to `is_busy` — "the turn actually started" — over the
absorbed-Enter false-positive that `is_typing` had missed. The third live
run (session 8e39f620) showed the other edge. The continuation fires from
`SessionStart(compact)`, i.e. the instant compaction completes, while the
session is still settling. A submit landing there is **queued**, not run:
the transcript recorded it (`promptSource: "queued"`) at 20:54:06, but the
queued turn's spinner did not appear until 20:54:19 — thirteen seconds
later, long past the ~1.5s confirm window. `is_busy` times the spinner, so
it reported "three Enters did not submit it" for a line that had in fact
arrived and would run.

The lesson across both runs: neither pane signal answers the actual question.
`is_typing` and `is_busy` both proxy *submission* through the pane — "composer
drained" or "turn running" — and each proxy has a state the other catches and it
misses. A queued submit is drained-and-accepted but not-yet-running; an absorbed
Enter is running-nothing and still-composing. No single pane predicate separates
all three of {absorbed, queued, fresh} because the pane conflates them.

The authoritative record is the transcript: an accepted prompt — queued or
fresh — is written as a `type:"user"` entry immediately, whereas an absorbed
Enter submits nothing and writes nothing. So line-2 confirmation now baselines
the count of genuine user-prompt entries containing the typed line, Enters, and
polls for that count to rise (`submit_confirmed_or_fail`,
`transcript_prompt_count` in `_rename-lib.sh`). `load-compact.sh` exports the
session `transcript_path` to the watcher; the entry appears within the confirm
window (it is synchronous with acceptance), so the poll needs no longer than
before.

Two guards against the obvious traps. The task text is typically strewn through
the transcript already — the compact summary, the injected frame, attachments —
so a raw substring grep would read as "submitted" before any Enter. The count
keys on the same structural flags as `handoff_activated` (`type:"user"`, not
`isMeta`/`isCompactSummary`/`isSidechain`), excluding every harness-injected
echo; and it is *baselined before the first Enter*, so a stale pre-compaction
copy of the same prompt cannot mask a real non-delivery. This is the JSONL
coupling the open decision flagged as the cost of the robust path — bounded to
one substring-in-decoded-content check over flag-filtered entries, the same
discipline the guards already carry, and preferred over the alternative
(downgrading the message to "could not confirm submission", which would have
retired the absorbed-Enter failure signal the previous run had just added).

Line 1 keeps `is_busy` (`submit_or_fail`). Its `/compact` is typed at `Stop`,
when the session is idle rather than settling, and submitting it starts the
compaction — a long, reliably-busy operation the spinner shows at once. Only the
continuation, firing into the post-compaction settle, is exposed to queueing.
(The premise in that last paragraph is false; superseded below, "The submit
signal, a third time".)
