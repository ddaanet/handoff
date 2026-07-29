# Mid-turn TUI input: the taxonomy that shapes compaction driving (2026-07-19)

The precompact-drive spec (`docs/2026-07-18-precompact-drive-design.md`)
proposed typing `/compact` and a continuation prompt into the pane via a
watcher spawned at `PostToolUse` time. That rested on an assumption carried
over from `write-rename.sh`: input typed while the agent is busy is queued
inertly and runs afterward. Renaming had never falsified it because a
mistimed `/rename` fails harmlessly.

A spike against v2.1.215 (recorded in the spec) showed there is no single
"queued" behavior. Four distinct classes exist: TUI-local commands (`/focus`)
are intercepted immediately and never queue; harness actions (`/compact`) queue
and are interpreted at the next turn boundary; plugin commands (`/handoff`)
queue and drain as their own turn; and **plain prose is injected into the
running turn's next model call**.

That last row is the load-bearing one. The continuation prompt — prose — was
the input the original design treated as safe and the compaction command was
the one it feared. It is the other way round. Slash-shaped input can never
reach the model as prose (an unrecognized command drains to `Unknown command`),
so the compaction step cannot induce a hallucinated compaction; but prose typed
into a live turn contaminates the work the continuation is supposed to follow.

The fix is to stop inferring idleness from the screen. `Stop` and
`SessionStart(compact)` are harness-authoritative and fire exactly at the two
boundaries the design needs, so both typed lines are gated on hooks; the
watchers keep an idle-wait, demoted from safety mechanism to settle delay.
`Stop` not firing on Esc interrupt makes an interrupted turn fail safe without
extra machinery.

Two incidental results are worth keeping. `is_busy` must read only the visible
pane — a `capture-pane -S` history read matches a stale timer and reports busy
long after `Stop`. And the suspicion that queued input bypasses
`UserPromptSubmit` — which would have meant `prompt-pre-hook.sh` silently
missing a `/handoff:handoff` typed at a busy session — is false: `/compact`
skips the hook because it never becomes a prompt, while a queued `/handoff`
fires it with the raw command text. The wipe path is sound.
