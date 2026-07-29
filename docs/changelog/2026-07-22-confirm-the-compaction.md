# The submit signal, a third time: confirm the compaction, not the keystroke (2026-07-22)

"A long, reliably-busy operation the spinner shows at once" was an assumption,
never a measurement. A live run falsified it: `/compact` was typed, Entered,
submitted at 20:06:46, and the compaction ran for 103 seconds — and the watcher
still wrote *"typed but three Enters did not submit it"*, which surfaced at the
next prompt as a failure report for something that had plainly worked. Whatever
the TUI renders in the ~1.5 seconds after that keystroke, `is_busy` does not
match it.

The transcript trick that fixed line 2 does not transfer. The `/compact` entry
carries the submit timestamp but is *persisted* only once the command finishes —
in the session JSONL it sits physically after the compact summary written 103
seconds later. Polling it would fail for exactly as long as `is_busy` did.

So line 1 stops asking "did the keystroke land?" and asks "did the compaction
happen?" — which is the question the report is about, and which has an
authoritative answer already in the design: `SessionStart(compact)` consumes
`autocompact.pending`. `stop-compact.sh` hands the watcher that path in
`HANDOFF_PENDING_FILE`, exactly as it already hands over `HANDOFF_FAIL_FILE`,
and `submit_consumed_or_fail` waits for the file to go. No pane read, no JSONL
read, no guess about chrome.

Three consequences, all accepted deliberately. Confirmation now takes minutes,
so a genuine non-delivery is reported one `CONSUME_TIMEOUT` late — but it
surfaces at the next `UserPromptSubmit` either way, and a false alarm is worse
than a slow one. The short Enter-retry burst stays, since it is the only
recovery from an unregistered keystroke, and its per-iteration check is now
near-vacuous. And with no file to confirm against the watcher exits 0: an
unconfirmable submit is not a failed one.

The wider lesson is the one this signal has now taught three times. Every
pane-derived predicate is a guess about undocumented chrome, and each has failed
in a different way — a stale scrollback timer reading as busy, a queued submit
showing no spinner, and now a compaction showing none either. `is_typing` and
`is_unknown_command` survive because they gate *typing into* the composer, where
the pane is the only witness there is. Nothing that asks whether an action
*took effect* should look at the pane again.
