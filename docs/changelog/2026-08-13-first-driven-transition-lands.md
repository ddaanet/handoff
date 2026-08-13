# 2026-08-13 — The first driven transition to land

The composer-predicate fix shipped in `ef4e82e`. The dogfood for it was the
obvious one: compact the session that wrote it, driven — a `/compact` carrying
a focus directive, then a continuation prompt on the far side.

Both lines landed hands-off. The sentinel was consumed by
`SessionStart(compact)`, no `.claude/autodrive.failed` was written, and the
continuation arrived as a genuine user prompt rather than something a human
pressed Enter on.

## What it proved that the suites could not

`_submit_until` had never run in production. Not once, since the walker was
built.

Every driven transition before this failed at the composer check — the U+00A0
defect was total, so the walker aborted each line *before* the first Enter.
Everything downstream of that abort was therefore unexercised: the three fast
retries at `VERIFY_DELAY`, the long poll that follows them without resending,
`submit_consumed` waiting on the sentinel to disappear, `submit_prompted`
counting genuine transcript entries. All of it was reasoned about carefully,
unit-tested against a tmux stub, and never once run against the real thing.

It was also the first exercise of the post-transition settle, where a prose
submit is accepted and transcript-logged immediately but shows no spinner
until the queued turn starts seconds later. That is why the prose primitive
counts transcript entries instead of reading the pane
([the submit signal, a third
time](2026-07-22-confirm-the-compaction.md)) — correct reasoning that had, until
now, only ever been checked against a stub reproducing the same assumption.

## Why a passing test is worth an entry

The interesting fact is not that it worked. It is that a load-bearing path sat
unexecuted for weeks behind a predicate that failed earlier in the same
function, while its own tests stayed green — the same shape as the defect that
hid the U+00A0 gap, one layer further down. A green unit suite says a stub
agrees with the code; it never says the code has run.

So the rule the design doc now carries: driving a transition for real is part
of landing a change that touches the walker, not a follow-up to it.

## Vestigial names

`is_typing` was deleted in the same commit, but its name survived in prose
that describes the current system: `docs/design.md`'s pane-reading paragraph,
four places in `CLAUDE.md`, and three docstrings under `scripts/`. Those now
name the predicates that exist. Occurrences in `docs/changelog/` and `plans/`
stay untouched — they are write-time records, and past tense there is correct.
