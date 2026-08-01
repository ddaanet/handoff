# 2026-08-01 — Nudge the boundary at a context-size threshold

A turn that runs long reaches no boundary. `Stop` and `UserPromptSubmit` fire
only at turn boundaries, which is precisely what a runaway turn escapes — the
agent goes busy, drives the prompt past 200k across a dozen tool batches, and
nothing in this plugin has a moment at which to notice. Every transition it
owns is armed at a boundary, so the one session that most needs a boundary is
the one it cannot reach.

`PostToolBatch` is the only hook event that fires *inside* a turn. It fires
once per assistant message, which is the session log's own granularity: one API
call, one `usage` sample. Its `additionalContext` reaches the model on the next
API call of the same turn — verified by live nested `claude -p` runs against
2.1.220, where call 1 was thinking plus a `tool_use` and call 2 read back
exactly the injected marker inside a single `-p` turn, so no user turn could
have carried it. The full verification pass is
[the brief](../../plans/2026-07-31-context-threshold-trigger-brief.md); the
design that followed it is
[the spec](../../plans/2026-07-31-context-threshold-trigger-design.md).

## What the threshold is for

Not survival. All non-Haiku models now carry 1M-token windows and
`autoCompactEnabled` is expected off, so a growing prompt hits no wall and the
harness enters no destructive boundary on its own. There is nothing to race.

A prompt at 150k is worth compacting because attention and cost say so — and
because *this plugin* can cross that boundary carrying the task frame and a
memory flush, where an untended session would just keep growing. That is the
whole argument. The trigger exists to convert a preference about context size
into the boundary the plugin already knows how to prepare.

## Nudge, not halt

One `additionalContext` injection naming `/handoff:compact-continue`. The two
halts were both verified to work — `continue: false` ends a running turn
(`--debug hooks` names the path, `requested preventContinuation`) and
`decision: "block"` converges on the same outcome by a different internal
route — and neither is used.

A halt produces no final assistant text. The turn simply ends: the batched
calls run, their results land in the transcript, and then nothing. It discards
in-flight work, reads as a silent stall, and *still* leaves the boundary
unprepared, because the user has to type the next move anyway. The nudge
already answers the motivating case, since it reaches the model mid-turn.

The halt is reopened when an ignored nudge is **observed** — a `usage` sample
well past threshold, the marker already present, and no `compact-continue` in
the transcript. Not before. Building the stronger lever against a failure
nobody has seen would be speculation.

The directive names `compact-continue` rather than `precompact`: the crossing
carries the transition out rather than preparing it and stopping. It inherits
the gitlore approval gate unchanged and is not special-cased — when memory is
dirty the agent summarizes and asks, and the arming discipline forbids arming
in the same turn as that question, so the compaction runs one turn later. That
is the standing decision *With nothing to approve, the wrap-up completes in a
single turn*, whose both halves survive here untouched.

## Fire once per climb; the re-arm is a boundary

A marker at `/tmp/claude/handoff-context-<session_id>`, beside the root pointer
and the drift marker. Present ⟹ exit immediately, before any transcript read.
Still over threshold means the boundary has not happened yet, and re-injecting
on every batch would burn the context the nudge exists to conserve.

The first draft cleared the marker by re-measuring under threshold. That is the
form this design rules out everywhere else: *nothing that asks whether an
action took effect infers it from a number.* `SessionStart` **is** the
harness-authoritative signal that the context was rebuilt, so
`session-pointer.sh` removes this session's marker right after publishing the
root, on every source — `compact` (auto-compaction included), `clear`, and
`resume`, where re-arming is also right, since a resumed session restores its
full context and deserves the nudge again if it is still over.

`handoff-context-*` joins that script's sweep filter, which now names three
prefixes at one level.

## Measurement, and what it is allowed to read

`tail -c 262144` of the transcript, drop the partial first line `tail` lands
on, take the **last** entry carrying `message.usage`, and sum `input_tokens +
cache_creation_input_tokens + cache_read_input_tokens`. No usage entry in the
window ⟹ exit 0; the next batch appends a fresh one.

Taking the last rather than summing across entries is what makes the repeated
`message.id` harmless — the several JSONL entries of one API response all
repeat the same `usage`, so no dedupe is needed. Summing would read three times
the truth on any ordinary batch.

This reads the transcript, which the design bans in a neighbouring form:
*keying on tool names in JSONL is a maintenance trap the harness has already
sprung once.* `message.usage` is a structural field, in the same family as
`transcript_title_count` and `transcript_prompt_count`, which already confirm
the walker's keystrokes from the transcript. It is not the rejected form.

## Subagent batches are skipped

`agent_id` present ⟹ exit 0, the cheapest possible negative path and the first
thing the script does. The remedy the directive names is meaningless inside a
subagent: it has no boundary to prepare and nothing that survives one. Worse,
`transcript_path` there points at the **parent** session file, whose newest
sample is stale for the duration of the subagent, while the subagent's own
usage lives at `<session-dir>/subagents/agent-<agent_id>.jsonl`. A naive read
measures the wrong context and then names a remedy that cannot be acted on.

Revisit only if a subagent is ever seen dying on its own context. The answer
then is a different directive — "stop exploring, return what you have" — not
this one.

## The first hook that is not cwd-scoped

`scripts/context-threshold.sh` touches no file under `.claude/`. It reads the
transcript named in its own payload and writes one marker under the pointer
directory, so it resolves no root, spawns no `python3`, and calls neither
`handoff_root` nor `handoff_match_target`. It sources `_lib.sh` only for
`HANDOFF_POINTER_DIR` and a new `handoff_context_path()` beside
`handoff_pointer_path()` — which is also what keeps the marker directory
overridable under test. Registered with `timeout: 5`, matching the other
per-event hooks.

Keeping the negative path cheap is NFR2, and this is the hottest path in the
plugin: it fires on every tool batch of every session with the plugin
installed. In the overwhelmingly common case the work is a `jq` over stdin and
a `stat`.

The user-facing `systemMessage` leads with an ANSI style reset, like the drift
report's. A compaction that appears to start on its own needs a stated cause,
and the hook chatter it sits among renders dimmed.

## Rejected

- *A byte-floor gate on the transcript before measuring.* It buys a fraction of
  an 8 ms `tail`+`jq` and smuggles in a tokenizer-ratio constant this design
  otherwise has none of. NFR2's precedent (`bash-post.sh`) defers a 45 ms
  `python3` spawn, not a `jq`.
- *A percentage of the window, or `autoCompactWindow`.* Both couple the plugin
  to something that moves: `autoCompactWindow` is an undocumented settings key
  reachable only through an undocumented `/autocompact`, and a model→window
  table goes stale on every release. Neither earns its keep for a number whose
  job is to express a preference about context size, not to track a limit. The
  threshold is a fixed `150000`, overridable by `HANDOFF_CONTEXT_THRESHOLD`.
- *`Stop` / `UserPromptSubmit` as the trigger.* Turn granularity — the case
  worth catching is the one that never reaches a turn boundary.
- *`PreCompact` as the trigger.* It fires only once compaction is already
  decided, blocking it does not defer it (the binary's own log reads
  `compaction blocked by PreCompact hook; continuing uncompacted`), and it has
  no `additionalContext` channel. A backstop at best, never a trigger.
- *The statusline as the trigger.* It does receive a real `context_window`
  object — `context_window_size`, `current_usage`, `used_percentage`,
  `exceeds_200k_tokens`, everything this change had to derive by hand. But it
  is not a hook: it renders text and has no channel back into the harness. It
  would need a sentinel file plus a second hook to do what one hook does
  directly.

## Known exposure

`PostToolBatch` is **undocumented** — absent from the binary's own schema
doc-strings and from `plugin-dev:hook-development`, its payload shape known
only from a live capture. gitlore already depends on the same event for its
standalone memory commit, so the exposure is shared rather than new. It is
still exposure, and a harness release can take it away.

One assumption is unverified at write time: that the main transcript never
carries a subagent's `usage` entry. Subagent usage lives in its own file, so
the main file's newest sample should be the main thread's. If that is wrong the
measurement reads high, and the fix is a `select(.isSidechain != true)` in the
`jq` filter. It settles at the first dogfood — which needs a restart, since
`hooks.json` is frozen at session start and the entry cannot take effect in the
session that adds it.
