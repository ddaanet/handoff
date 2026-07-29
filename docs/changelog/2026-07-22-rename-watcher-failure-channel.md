# The rename watcher joins the failure channel (2026-07-22)

The 2026-07-20 pass gave the compaction watchers a way to report a line that
never landed and left the rename watcher out, even while naming its `is_typing`
bail as the archetype of "the same shape [that] used to `exit 0`,
indistinguishable from success". It was written first and the retrofit did not
reach back to it: both its non-delivery paths — the composing-bail and three
failed verifies — ended in a bare exit nobody reads, `write-rename.sh` never
exported `HANDOFF_FAIL_FILE` for it to write to, and no consumer existed on the
rename side. So the hook announced "will rename to X once idle" and nothing ever
contradicted it.

The fix is entirely existing parts: `watcher_fail` at both exits,
`HANDOFF_FAIL_FILE` exported by `write-rename.sh` as `stop-compact.sh` already
does, and one more file for the consumer to read. The consumer did not need
duplicating — `report-compact-failure.sh` becomes `report-watcher-failure.sh`
and reads both files, joining whatever it finds into a single message. They
differ only in which line never landed; a second `UserPromptSubmit` hook doing
the same work under a different name would be the vestigial half-measure, not
the general one.

`.pending` stays coupled to the compaction failure alone. A rename says nothing
about a compaction, so clearing it on that evidence would race a live
`SessionStart(compact)` — the same reasoning as the stale-`autocompact` sweep.
