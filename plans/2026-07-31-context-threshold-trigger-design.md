## Nudge the boundary when the context crosses a size threshold

2026-07-31 — target repo: `handoff`

The verification pass that established the mechanism is
[`2026-07-31-context-threshold-trigger-brief.md`](2026-07-31-context-threshold-trigger-brief.md).
Everything it records as verified is taken as given here and not repeated.

### Purpose

A turn that runs long has no boundary at which anything can notice. `Stop` and
`UserPromptSubmit` fire only at turn boundaries, which is precisely what a
runaway turn escapes. `PostToolBatch` fires once per assistant message — the
session log's own granularity, one API call, one `usage` sample — and its
`additionalContext` reaches the model on the next call *of the same turn*.

What this buys is **context quality and economics**, not survival. All
non-Haiku models now carry 1M-token windows and `autoCompactEnabled` is
expected off, so there is no wall to race and no destructive boundary the
harness enters on its own. A prompt that has grown to 150k tokens is worth
compacting because attention and cost say so, and because the plugin can cross
that boundary carrying the task frame and a memory flush where an untended
session would just keep growing.

### Decisions

1. **Nudge only. No halt.** One `additionalContext` injection. `continue:
   false` and `decision: "block"` both halt a running turn and are verified to
   work, but a halt produces no final assistant text, discards in-flight work,
   and still leaves the boundary unprepared — the user has to type the next
   move anyway. The nudge already answers the motivating case, since it reaches
   the model mid-turn.

   Reopen it when an ignored nudge is *observed*: a `usage` sample well past
   threshold with the marker already present and no `compact-continue` in the
   transcript. Not before.

2. **A fixed token threshold, env-overridable.** `HANDOFF_CONTEXT_THRESHOLD`,
   default `150000`. Compared directly against the measured prompt size — no
   percentage, no window discovery. The alternatives both couple the plugin to
   something that moves: `autoCompactWindow` is an undocumented settings key,
   and a model→window table goes stale on every release. Neither earns its
   keep for a number whose job is to express a preference about context size,
   not to track a limit.

3. **Subagent batches are skipped.** `agent_id` present ⟹ exit 0. The remedy
   the directive names is meaningless inside a subagent: it has no boundary to
   prepare and nothing that survives one. Measuring the parent's transcript
   from inside a subagent measures a stale number, and the subagent's own usage
   lives in a different file. This is also the cheapest possible negative path
   — one `jq` field test.

   Revisit only if a subagent is ever seen dying on its own context; the answer
   then is a different directive ("stop exploring, return what you have"), not
   this one.

4. **The directive names `/handoff:compact-continue`.** The threshold crossing
   carries the transition out rather than preparing it. This is the seamless
   posture, chosen deliberately over `precompact` — which would prepare and
   stop, leaving the user to type `/compact`.

   It inherits the gitlore approval gate unchanged. When memory is dirty the
   agent must summarize and ask, and the arming discipline forbids arming in
   the same turn as that question, so the compaction runs one turn later. That
   is the standing decision *With nothing to approve, the wrap-up completes in
   a single turn* ([`docs/design.md`](../docs/design.md)), whose both halves
   any rebalancing must preserve. It is **not** special-cased here.

5. **One new script, `scripts/context-threshold.sh`, on a new `PostToolBatch`
   hook entry.** Role-shaped name after `write-guard` / `stop-drive`; "batch"
   is the trigger, not the job. Bash, per the hot/cold split in
   [the Python brief](2026-07-31-python-rewrite-brief.md) — this is the hottest
   path in the plugin and the work is a `stat`, a `tail` and two `jq` calls.

   It is the **first hook that is not cwd-scoped**. It touches no file under
   `.claude/`, so it resolves no root, spawns no `python3`, and calls neither
   `handoff_root` nor `handoff_match_target`. It sources `_lib.sh` only for
   `HANDOFF_POINTER_DIR` and a new `handoff_context_path()` beside
   `handoff_pointer_path()` — which is also what keeps the marker directory
   overridable under test. Registered with `timeout: 5`, matching the other
   per-event hooks.

6. **Fire once per climb; the marker is a gate, and the re-arm is a boundary.**
   A marker at `/tmp/claude/handoff-context-<session_id>`, beside the root
   pointer and the drift marker.

   - Marker present ⟹ exit immediately, before any transcript read. Still over
     threshold, because the boundary has not happened yet; re-injecting every
     batch would burn the context the nudge exists to conserve.
   - `session-pointer.sh` removes the marker right after publishing the root,
     on every `SessionStart` source. That is the re-arm.

   Clearing it by re-measuring under threshold was the first draft, and it is
   the form the design already rules out: *nothing that asks whether an action
   took effect infers it from a number*. `SessionStart` **is** the
   harness-authoritative signal that the context was rebuilt — `compact`
   (auto-compaction included), `clear`, and `resume`, where re-arming is also
   right, since a resumed session restores its full context and deserves the
   nudge again if it is still over.

   `handoff-context-*` joins the sweep's name filter in `session-pointer.sh`.

7. **Measurement: the newest `usage` in a tail window.** `tail -c 262144` of
   the transcript, drop the partial first line, take the **last** entry
   carrying `message.usage`, sum `input_tokens + cache_creation_input_tokens +
   cache_read_input_tokens`. No complete entry in the window ⟹ exit 0; the next
   batch appends a fresh one.

   Taking the last rather than summing across entries is what makes the
   `message.id` duplication harmless — the several JSONL entries of one API
   response all repeat the same `usage`, so no dedupe is needed.

   This reads the transcript, which the design bans in a neighbouring form:
   *keying on tool names in JSONL is a maintenance trap the harness has already
   sprung once*. `message.usage` is a structural field, in the same family as
   `transcript_title_count` and `transcript_prompt_count`, which already
   confirm the walker's keystrokes from the transcript. It is not the rejected
   form.

8. **The user is told.** A one-line `systemMessage`, leading with an ANSI style
   reset like the drift report's, so a compaction that appears to start on its
   own has a stated cause and is not rendered dimmed among ordinary hook
   chatter.

**Rejected**

- *A byte-floor gate on the transcript before measuring.* It buys a fraction of
  an 8 ms `tail`+`jq` and smuggles in a tokenizer-ratio constant this design
  otherwise has none of. NFR2's precedent (`bash-post.sh`) defers a 45 ms
  `python3` spawn, not a `jq`.
- *`Stop` / `UserPromptSubmit` as the trigger.* Turn granularity — the case
  worth catching is the one that never reaches a turn boundary.
- *`PreCompact` as the trigger.* Fires only once compaction is already decided,
  blocking it does not defer it (`compaction blocked by PreCompact hook;
  continuing uncompacted`), and it has no `additionalContext` channel.
- *The statusline as the trigger.* It does receive a real `context_window`
  object, but it is not a hook: it renders text and has no channel back into
  the harness. It would need a sentinel file plus a second hook to do what one
  hook does directly.

### Sequence

Per firing, in order, each step exiting 0 on its own miss:

1. One `jq` over stdin → `agent_id`, `transcript_path`, `session_id`.
   `agent_id` non-null ⟹ exit.
2. Marker exists ⟹ exit.
3. `tail -c` + `jq` → prompt size. No usage entry in the window ⟹ exit.
4. Below `HANDOFF_CONTEXT_THRESHOLD` ⟹ exit.
5. Write the marker; emit `additionalContext` and `systemMessage`.

`session-pointer.sh` gains one line after the pointer write: remove this
session's marker. Its sweep filter gains `handoff-context-*`.

### The directive

`additionalContext`, stating the act and nothing else — no mechanism, no
explanation of the hook that produced it:

> This session's prompt reached 152000 tokens, past the 150000 handoff
> threshold. Finish the step you are on, then run `/handoff:compact-continue`.

`systemMessage`:

> `handoff: context 152k, past 150k — asked the agent to run compact-continue`

### Testing

New rows in `tests/hook-test.bats`, over a synthetic transcript fixture:

- subagent skip (`agent_id` present)
- marker present ⟹ silent, and the transcript is not read
- below threshold ⟹ silent, no marker written
- first crossing ⟹ directive, `systemMessage`, marker written
- duplicate `message.id` entries ⟹ measured once, not summed
- no usage entry in the tail window ⟹ silent
- partial first line in the window ⟹ dropped, not parsed
- `HANDOFF_CONTEXT_THRESHOLD` override honoured
- `session-pointer.sh` clears the marker, on more than one source
- the sweep's new prefix expires with the other two, and its two guard-rails
  (name scope, `-maxdepth 1`) still hold

Two negatives are load-bearing and get paired positives over the same fixture,
mutation-checked rather than observed passing: the subagent skip, and the
marker gate. Disable each and watch the paired positive stay green while the
negative goes red.

### Docs and version

Same pass, per `CLAUDE.md`: a `docs/changelog/` entry plus its index line, and
the `docs/design.md` prose this invalidates.

`docs/design.md` gains a design decision — *the threshold is a context-quality
and cost policy, not a race against a destructive boundary* — and needs its
architecture line corrected: it says "eight hooks" where there are nine today,
and this makes ten.

Version: minor bump. A new hook entry point, but no change to the shape of
either file that crosses a boundary, so not a breaking change.

### Risks

- **`PostToolBatch` is undocumented.** Absent from the binary's own schema
  doc-strings and from `plugin-dev:hook-development`; the payload shape is
  known only from a live capture. gitlore already depends on the same event for
  its standalone memory commit, so the exposure is shared rather than new — but
  it is exposure.
- **The main transcript is assumed free of subagent `usage` entries.** Subagent
  usage lives in `<session-dir>/subagents/agent-<agent_id>.jsonl`, so the main
  file's newest `usage` should be the main thread's. Settled at first dogfood;
  if wrong, the read filters on the absence of `isSidechain`.
