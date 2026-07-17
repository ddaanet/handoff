## Current task

Scraping-machinery removal from the handoff plugin is done (frame is now a timestamp header plus the inlined task file; `extract.py`, the `handoff-session` pointer, the `Session:` line, and `handoff-error.log` are gone; precommit green); the remaining ship step is a minor version bump via `just release` (behavior changed — the frame and the machine-local files — but nothing user-facing breaks).

## Open decisions

- Whether to correct the `reference_jsonl_slash_command_shape` memory: it still names the removed `extract.py` as the `isMeta`/`isSidechain` filter site, but the live filter is now `handoff_activated()` in `_lib.sh` only.
