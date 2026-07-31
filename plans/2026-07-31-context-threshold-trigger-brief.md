## Brief: context-size threshold trigger via PostToolBatch

2026-07-31

Findings from a verification pass, as the starting point for a design pass.
Nothing here is a decision — the mechanism is established, the design is not.

### Problem

The case worth catching is a single turn where the agent goes busy and drives
context past 200k without ever reaching a turn boundary. `Stop` and
`UserPromptSubmit` fire only at turn boundaries, so they cannot see it happen.
`PostToolBatch` fires per tool batch, which is the session log's own
granularity — one API call, one assistant message, one `usage` sample.

### Verified

Against Claude Code 2.1.220, by live nested `claude -p` runs; session
transcripts cited are under
`~/.claude/projects/-Users-david-code-handoff/`.

- **No hook event carries token counts.** Base input is `session_id`,
  `transcript_path`, `cwd`, plus optional `prompt_id`, `permission_mode`,
  `agent_id`, `agent_type`, `effort`. No context percentage or window size on
  any event.
- **`PostToolBatch` stdin** additionally carries `tool_calls[]`, each entry
  `tool_name` / `tool_input` / `tool_use_id` / `tool_response` (already
  resolved). Undocumented — absent from the binary's own schema doc-strings,
  visible only in a live payload. Inside a subagent it also carries `agent_id`
  and `agent_type`.
- **Cadence**: one firing per assistant message, batching every `tool_use`
  block of that message. Confirmed by three transcript entries sharing one
  `message.id` (`msg_011Cdafn…`, session `00d7b844`) against a single firing.
- **`hookSpecificOutput.additionalContext` reaches the model on the next API
  call of the same turn.** Session `fb399625`: call 1 is thinking + `tool_use`
  (ctx 39297), call 2 is thinking + text reading exactly the injected marker
  (ctx 39543). Single `-p` turn, so no user turn could have carried it.
- **`continue: false` halts a running turn.** Sessions `00d7b844` and
  `061d9cb2`: both batched Bash calls ran, their results are in the transcript,
  and the turn then ends — no further API call, no final text, despite a prompt
  demanding one. `--debug hooks` names the path:
  `Hook PostToolBatch (...) requested preventContinuation`.
- **`decision: "block"` also halts**, via a different internal path
  (`permissionDecision: deny`), converging on the same outcome. Reported by the
  research agent with a debug-log citation; not independently re-verified.
- **Transcript is fresh at fire time** — the assistant entry carrying `usage`
  for the call that issued the batch is on disk ~0.2s before the hook runs.
- **`usage` math**: `input_tokens + cache_creation_input_tokens +
  cache_read_input_tokens` on the newest assistant entry is the prompt size
  sent for that call. Counts after a compaction are accurate.
- **`autoCompactEnabled`** is documented (default true, `DISABLE_AUTO_COMPACT`).
  **`autoCompactWindow`** exists in the binary's settings schema, set via an
  undocumented `/autocompact [auto|<tokens>]`; the effective threshold is the
  minimum of it and the model's window.

### Constraints

- A halt produces **no final assistant text** — the turn just ends. Without a
  `systemMessage` it reads as a silent stall, the same observability gap
  `report-watcher-failure.sh` exists to close for the walker.
- Reading `usage` requires deduping on `message.id`: one API response emits
  several JSONL entries sharing an id, all repeating the same `usage`.
- Inside a subagent, `transcript_path` points at the **parent** session file.
  The subagent's own usage lives at
  `<session-dir>/subagents/agent-<agent_id>.jsonl`. A naive read measures the
  wrong context.
- `PostToolBatch` fires on every batch in every session with the plugin
  installed, so the negative path must stay cheap (NFR2).
- Hooks cannot inject tool calls or keystrokes. The levers are exactly:
  `additionalContext`, `systemMessage`, and the two halts.

### Rejected approaches

- **`Stop` / `UserPromptSubmit` as the trigger** — turn granularity, which is
  precisely what the runaway-turn case escapes.
- **`PreCompact` as the primary mechanism** — fires only once compaction is
  already decided, and blocking it does not defer it: the binary's own log
  reads `compaction blocked by PreCompact hook; continuing uncompacted`. It has
  no `additionalContext` channel. Usable as a hard backstop, not as a trigger.
- **Statusline as the trigger** — it does receive a real `context_window`
  object (`context_window_size`, `current_usage`, `used_percentage`,
  `exceeds_200k_tokens`), but it is not a hook: it renders text and has no
  channel back into the harness. Would need a sentinel file plus a second hook.

### Open for the design pass

- Soft threshold (inject a directive to run `compact-continue`) versus a hard
  one (halt). Whether the halt is in scope at all.
- Where the window size comes from: a hardcoded figure, or the internal
  `autoCompactWindow` key — which couples the plugin to an undocumented
  setting.
- Which script owns this, and how it composes with the existing hook set.
- Whether subagent batches are measured at all, or skipped when `agent_id` is
  present.
