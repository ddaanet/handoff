## Current task

Ship handoff v0.10.0 via `just release minor` (tags `handoff` and bumps the
`claude-plugins` marketplace entry): the whole-plugin simplify consolidation
(shared `_lib.sh`/`_rename-lib.sh` helpers) plus four review doc fixes.
Residual code thread: `submit_or_fail`'s `is_busy` confirmation false-fails
when a submission lands in the prompt queue — third live run (session
8e39f620) delivered the continuation line (JSONL `queue-operation` enqueue →
`promptSource: "queued"`) but no spinner showed in the 3×0.5s confirm
window, so the watcher reported "three Enters did not submit it" for a line
that arrived.

## Open decisions

- How to fix the queued-submission false failure: harness-side confirmation
  (the spawning hook receives `transcript_path` and could hand it to the
  watcher, which greps the transcript tail for its line) vs downgrading the
  fail wording to "could not confirm submission". Transcript-tail is robust
  but couples watchers to the undocumented JSONL format.
