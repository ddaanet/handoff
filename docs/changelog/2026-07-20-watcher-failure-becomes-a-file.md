# A detached watcher's failure has to become a file (2026-07-20)

The second live run was clean end to end — Stop armed, `/compact` typed and
submitted, the frame injected, the continuation auto-submitted with no keystroke
from the operator. The task file's open decision said to add failure
observability only "if this run's submit looks marginal", and that framing was
wrong in kind. A clean run says nothing about whether a dirty one would be
noticed. The failing run is the one that needs the breadcrumb, and it is exactly
the run where nobody is watching.

The watchers are spawned detached, so their exit status is read by nothing. That
leaves three non-delivery paths. The line-2 Enter failing is invisible to the
agent but visible to the operator — the prose sits in the composer, which is
precisely how the first run's defect surfaced. The `is_typing` bail is the same
shape and used to `exit 0`, indistinguishable from success. The dangerous one is
the line-1 recognition abort: `compact-when-idle.sh` sends `C-u` and gives up,
wiping the composer, so the pane looks untouched, no compaction happens, and the
agent continues on a full context believing it armed one.

So the watchers write the reason to `.claude/autocompact.failed` and
`report-watcher-failure.sh` surfaces it on both channels at the next
`UserPromptSubmit`. `UserPromptSubmit` rather than `Stop`: a watcher runs *after*
the Stop that spawned it, so the next Stop is a full turn later, while the next
prompt is the first moment anything can act on the news.

The path comes from the spawning hook as `HANDOFF_FAIL_FILE` rather than being
derived in the watcher, keeping the layout knowledge in the hooks. And the report
fires only on paths a watcher observed itself — never inferred from a stale
`.pending`, which is legitimately present for the whole Stop → compaction window
and would produce false alarms on a race with the operator typing. A watcher
killed outright is therefore still silent; a false-positive-free signal is worth
more than that tail.
