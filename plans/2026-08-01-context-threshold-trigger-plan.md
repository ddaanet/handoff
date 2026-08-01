# Context-size threshold trigger — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nudge the agent to run `/handoff:compact-continue` once this session's
prompt crosses 150k tokens, measured per tool batch.

**Architecture:** A new `PostToolBatch` hook reads the newest `usage` sample
from the tail of the session transcript, compares the summed prompt size against
a threshold, and injects one directive. It fires once per climb, gated by a
session-keyed marker under `/tmp/claude` that `session-pointer.sh` clears at the
next `SessionStart` — the boundary is the re-arm, not a re-measurement.

**Tech Stack:** bash + `jq`, bats.

**Spec:** [`2026-07-31-context-threshold-trigger-design.md`](2026-07-31-context-threshold-trigger-design.md).
Read it before Task 1; every decision below is justified there.

**Execution.** Task 1 is the one worth a fresh agent: large, fully specified,
mechanical once the rows are written. Task 2 is two four-line edits and five
rows — better handed to the same agent as a second prompt than given its own
prime, but behind a review gate, because widening the sweep filter is the only
edit here that can regress something already working. **Task 3 is not
delegated.** The changelog entry is a write-time record of reasoning that lives
in the spec and the session that produced it, and `docs/design.md` and
`CLAUDE.md` are written in a voice a context-free agent does not have; its
output would be rewritten wholesale.

## Global Constraints

- The script is **not cwd-scoped**. It touches no file under `.claude/`, so it
  must not call `handoff_root`, `handoff_root_read`, `handoff_match_target`, or
  spawn `python3`. NFR2: `PostToolBatch` fires on every tool batch of every
  session with the plugin installed.
- Threshold: `HANDOFF_CONTEXT_THRESHOLD`, default `150000` tokens.
- Tail window: `HANDOFF_CONTEXT_WINDOW`, default `262144` bytes.
- Marker: `$HANDOFF_POINTER_DIR/handoff-context-<session_id>`, addressed only
  through `handoff_context_path()`.
- Prompt size = `input_tokens + cache_creation_input_tokens +
  cache_read_input_tokens` on the **last** entry carrying `.message.usage`.
  Taking the last — never summing across entries — is what makes the repeated
  `message.id` harmless.
- `set -euo pipefail` and `# shellcheck source-path=SCRIPTDIR source=_lib.sh`
  above the `source` line, as in every sibling script.
- Every step's tests are `bats tests/hook-test.bats`; the full gate before any
  commit is `just precommit`.
- No `2>/dev/null` blanket suppression (house rule); guard instead.

## File Structure

| file | change | responsibility |
|---|---|---|
| `scripts/context-threshold.sh` | create | the whole trigger: parse, gate, measure, emit |
| `scripts/_lib.sh` | modify | `handoff_context_path()`, beside `handoff_pointer_path()` |
| `scripts/session-pointer.sh` | modify | clear the marker; sweep the new prefix |
| `hooks/hooks.json` | modify | one `PostToolBatch` entry, `timeout: 5` |
| `tests/hook-test.bats` | modify | runner, fixture builder, rows |
| `docs/changelog/2026-08-01-context-threshold-trigger.md` | create | write-time record |
| `docs/changelog.md` | modify | index line |
| `docs/design.md` | modify | new decision; hook count |
| `CLAUDE.md` | modify | script inventory + hook list |

---

### Task 1: The measurement script, and the hook that dispatches to it

The registration is part of this task rather than its own. A script the
manifest never names is dead code that passes every test above it, so there is
no point at which the script is a deliverable and the entry is not — and the
row that asserts the dispatch asserts the script's existence in the same
breath, so it could not run before this task anyway.

**Files:**
- Create: `scripts/context-threshold.sh`
- Modify: `scripts/_lib.sh` (after `handoff_pointer_path`, ~line 47)
- Modify: `hooks/hooks.json` (new `PostToolBatch` key under `.hooks`, and the
  `description` string)
- Test: `tests/hook-test.bats` (new block, after the `session-pointer` block)

**Interfaces:**
- Consumes: `HANDOFF_POINTER_DIR` from `_lib.sh`.
- Produces: `handoff_context_path <session_id>` → prints
  `$HANDOFF_POINTER_DIR/handoff-context-<session_id>`. Task 2 calls it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hook-test.bats`:

```bash
# --- context-threshold (PostToolBatch: nudge once the prompt crosses a size) ---
#
# A turn that runs long has no boundary at which anything can notice: Stop and
# UserPromptSubmit fire only at turn boundaries, which is what a runaway turn
# escapes. PostToolBatch fires once per assistant message — one API call, one
# usage sample — and its additionalContext reaches the model on the next call
# of the same turn.

# One assistant entry: $1 message id, $2 input, $3 cache_creation, $4 cache_read.
usage_entry() {
    jq -nc --arg id "$1" --argjson i "$2" --argjson cc "$3" --argjson cr "$4" \
        '{type:"assistant", message:{id:$id, usage:{
            input_tokens:$i, cache_creation_input_tokens:$cc,
            cache_read_input_tokens:$cr}}}'
}

run_context_threshold() {
    local tp="$1" sid="${2-$SESSION_ID}" aid="${3-}"
    run bash -c '
        jq -nc --arg tp "$1" --arg sid "$2" --arg aid "$3" \
          "{transcript_path:\$tp, session_id:\$sid,
            hook_event_name:\"PostToolBatch\"}
           + (if \$aid == \"\" then {} else {agent_id:\$aid} end)" \
        | bash scripts/context-threshold.sh
    ' _ "$tp" "$sid" "$aid"
}

# The positive both load-bearing negatives are paired against. Mutate either
# guard and this row must stay green while its negative goes red — otherwise
# the negative was passing for the wrong reason.
@test "context-threshold (over threshold: nudges and writes the marker)" {
    usage_entry m1 100000 30000 40000 > "$tmp/t.jsonl"
    run_context_threshold "$tmp/t.jsonl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"compact-continue"* ]]
    [[ "$output" == *"170000"* ]]
    [ -e "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID" ]
}

# Load-bearing negative 1. A subagent has no boundary to prepare and nothing
# that survives one, and its own usage lives in another file entirely — so the
# number here is the parent's, and stale.
@test "context-threshold (subagent: silent, no marker)" {
    usage_entry m1 100000 30000 40000 > "$tmp/t.jsonl"
    run_context_threshold "$tmp/t.jsonl" "$SESSION_ID" "agent-42"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -e "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID" ]
}

# Load-bearing negative 2. Still over threshold, because the boundary has not
# happened yet; re-injecting every batch would burn the context the nudge
# exists to conserve.
@test "context-threshold (marker present: silent, no second nudge)" {
    usage_entry m1 100000 30000 40000 > "$tmp/t.jsonl"
    mkdir -p "$HANDOFF_POINTER_DIR"
    touch "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID"
    run_context_threshold "$tmp/t.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "context-threshold (under threshold: silent, no marker)" {
    usage_entry m1 10000 2000 3000 > "$tmp/t.jsonl"
    run_context_threshold "$tmp/t.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -e "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID" ]
}

# One API response emits several JSONL entries sharing a message id, each
# repeating the same usage. Summing across them would read 180000 here and
# nudge; taking the last reads 60000 and stays silent.
@test "context-threshold (repeated message id: counted once, not summed)" {
    { usage_entry m1 60000 0 0; usage_entry m1 60000 0 0
      usage_entry m1 60000 0 0; } > "$tmp/t.jsonl"
    run_context_threshold "$tmp/t.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "context-threshold (no usage entry in the window: silent)" {
    printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$tmp/t.jsonl"
    run_context_threshold "$tmp/t.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# tail -c lands mid-line. The partial head must be dropped, not fatal.
@test "context-threshold (partial first line: dropped, still measures)" {
    { printf '%s\n' '{"type":"assistant","message":{"id":"trunc","usa'
      usage_entry m2 100000 30000 40000; } > "$tmp/t.jsonl"
    run_context_threshold "$tmp/t.jsonl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"compact-continue"* ]]
}

@test "context-threshold (threshold override honoured)" {
    usage_entry m1 1000 500 500 > "$tmp/t.jsonl"
    HANDOFF_CONTEXT_THRESHOLD=1500 run_context_threshold "$tmp/t.jsonl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"compact-continue"* ]]
}

@test "context-threshold (no transcript file: silent)" {
    run_context_threshold "$tmp/absent.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "context-threshold (no session id: silent)" {
    usage_entry m1 100000 30000 40000 > "$tmp/t.jsonl"
    run_context_threshold "$tmp/t.jsonl" ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# The invocation path, not just the code: a script the manifest never names
# runs at no point, and every row above would still pass.
@test "context-threshold (hooks.json dispatches PostToolBatch to it)" {
    cmd="$(jq -r '.hooks.PostToolBatch[0].hooks[0].command' hooks/hooks.json)"
    [[ "$cmd" == *"scripts/context-threshold.sh"* ]]
    [ -f "scripts/context-threshold.sh" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/hook-test.bats -f context-threshold`
Expected: every row FAILs. The ten measurement rows die on
`scripts/context-threshold.sh: No such file or directory` (exit 127, so the
`[ "$status" -eq 0 ]` in each silent-case row is what catches them — none pass
vacuously); the dispatch row fails because `jq` prints `null`.

- [ ] **Step 3: Add the marker path helper**

In `scripts/_lib.sh`, immediately after `handoff_pointer_path()`:

```bash
# Path of the context-threshold marker for session id $1. Written when the
# nudge fires and removed by session-pointer.sh at the next SessionStart: the
# nudge fires once per climb, and the boundary is what re-arms it. A helper
# rather than an inline path (as the drift marker is) because two scripts
# address it — the same reason handoff_pointer_path exists.
handoff_context_path() {
    printf '%s/handoff-context-%s\n' "$HANDOFF_POINTER_DIR" "$1"
}
```

- [ ] **Step 4: Write the script**

Create `scripts/context-threshold.sh`:

```bash
#!/usr/bin/env bash
# PostToolBatch: nudge the agent across a boundary once this session's prompt
# has grown past a threshold.
#
# A turn that runs long has no boundary at which anything can notice — Stop and
# UserPromptSubmit fire only at turn boundaries, which is exactly what a
# runaway turn escapes. PostToolBatch fires once per assistant message, the
# session log's own granularity: one API call, one usage sample. Its
# additionalContext reaches the model on the next call of the same turn.
#
# What this buys is context quality and cost, not survival: the non-Haiku
# windows are 1M and auto-compaction is expected off, so there is no wall to
# race. A prompt at 150k is worth compacting because attention and price say
# so, and the plugin can cross that boundary carrying the task frame and a
# memory flush where an untended session would just keep growing.
#
# Not cwd-scoped — the only hook that is not. It reads the transcript named in
# its own payload and writes one marker under the pointer directory, so it
# resolves no root and spawns no python3. NFR2: this fires on every tool batch
# of every session with the plugin installed.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

{ read -r agent_id; read -r session_id; read -r transcript; } < <(
    jq -r '.agent_id // "", .session_id // "", .transcript_path // ""'
)

# A subagent has no boundary to prepare and nothing that survives one, so the
# directive below would name a remedy it cannot act on. Its own usage lives in
# <session-dir>/subagents/agent-<agent_id>.jsonl; transcript_path here points
# at the parent, whose newest sample is stale for the duration of the subagent.
[[ -z "$agent_id" ]] || exit 0

[[ -n "$session_id" ]] || exit 0

# Fire once per climb, and gate on it before touching the transcript. Still
# over threshold means the boundary has not happened yet; re-injecting every
# batch would burn the context the nudge exists to conserve. session-pointer.sh
# clears this at the next SessionStart, which is the harness-authoritative
# signal that the context was rebuilt.
marker="$(handoff_context_path "$session_id")"
[[ ! -e "$marker" ]] || exit 0

[[ -n "$transcript" && -f "$transcript" ]] || exit 0

# The newest usage sample in the tail window. `inputs` with `fromjson? // empty`
# skips the partial line tail -c lands on, and `last` — rather than a sum — is
# what makes the repeated message id harmless: the several JSONL entries of one
# API response each repeat the same usage.
size="$(
    tail -c "${HANDOFF_CONTEXT_WINDOW:-262144}" "$transcript" |
        jq -Rn '[inputs
                 | fromjson? // empty
                 | select(.message.usage)
                 | .message.usage
                 | (.input_tokens // 0)
                   + (.cache_creation_input_tokens // 0)
                   + (.cache_read_input_tokens // 0)]
                | last // empty'
)"
[[ -n "$size" ]] || exit 0

threshold="${HANDOFF_CONTEXT_THRESHOLD:-150000}"
(( size >= threshold )) || exit 0

mkdir -p "$HANDOFF_POINTER_DIR"
: > "$marker"

# Lead the user-facing line with a style reset: a compaction that appears to
# start on its own needs a stated cause, and the hook chatter it sits among is
# rendered dimmed.
jq -nc --arg lead $'\033[0m' \
    --arg brief "context ${size}, past ${threshold}" \
    --arg note "This session's prompt reached ${size} tokens, past the ${threshold} handoff threshold. Finish the step you are on, then run /handoff:compact-continue." '{
    systemMessage: ($lead + "handoff: " + $brief + " — asked the agent to run compact-continue."),
    hookSpecificOutput: {
        hookEventName: "PostToolBatch",
        additionalContext: $note
    }
}'
```

- [ ] **Step 5: Register the hook**

In `hooks/hooks.json`, add after the `PostToolUse` array:

```json
    "PostToolBatch": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/context-threshold.sh",
            "timeout": 5
          }
        ]
      }
    ],
```

No matcher — `PostToolBatch` fires per batch, not per tool. Extend the file's
`description` string to name the new hook alongside the others.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/hook-test.bats -f context-threshold`
Expected: 11 rows PASS.

- [ ] **Step 7: Mutation-check the subagent skip**

Comment out the `[[ -z "$agent_id" ]] || exit 0` line. Run:
`bats tests/hook-test.bats -f context-threshold`
Expected: *"subagent: silent, no marker"* FAILS, *"over threshold: nudges and
writes the marker"* still PASSES. Restore the line and confirm green again. If
the negative stayed green, it was passing for the wrong reason — fix the row,
not the script.

- [ ] **Step 8: Mutation-check the marker gate**

Comment out the `[[ ! -e "$marker" ]] || exit 0` line. Run the same command.
Expected: *"marker present: silent, no second nudge"* FAILS, *"over threshold"*
still PASSES. Restore and confirm green.

Paste both mutation runs' `bats` output verbatim into the report for this task.
The rows and the script are written by the same pass here, so the mutation is
the only thing standing in for a red-phase review — a claim that it went red is
not the same evidence as the run that did.

- [ ] **Step 9: Commit**

```bash
just precommit
git add scripts/context-threshold.sh scripts/_lib.sh hooks/hooks.json tests/hook-test.bats
git commit -m "✨ nudge the boundary once the prompt crosses a size threshold"
```

Hooks are frozen at session start, so the new entry does not take effect in the
session that adds it. Dogfooding it needs an exit and a fresh `claude`.

---

### Task 2: The re-arm at `SessionStart`

Until this lands, the marker Task 1 writes is cleared by nothing, so the nudge
fires once per session *lifetime* rather than once per climb — a compaction
keeps the same session id. That is one commit's window and it degrades to
silence rather than to noise, but do not leave the pair split across a release.

**Files:**
- Modify: `scripts/session-pointer.sh:33` (after the pointer write) and `:52-54`
  (the sweep filter)
- Test: `tests/hook-test.bats` (the existing `session-pointer` block)

**Interfaces:**
- Consumes: `handoff_context_path` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

Add to the `session-pointer` block in `tests/hook-test.bats`, after
*"creates the pointer directory"*:

```bash
# The context-threshold nudge fires once per climb and this is the re-arm. A
# SessionStart means the context was rebuilt: compact (auto-compaction
# included), clear, or a resume that restored it whole and may still be over.
@test "session-pointer (clears this session's context marker)" {
    mkdir -p "$HANDOFF_POINTER_DIR"
    touch "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID"
    run_session_pointer "$tmp" "$SESSION_ID" compact
    [ "$status" -eq 0 ]
    [ ! -e "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID" ]
}

@test "session-pointer (clears the context marker on resume too)" {
    mkdir -p "$HANDOFF_POINTER_DIR"
    touch "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID"
    run_session_pointer "$tmp" "$SESSION_ID" resume
    [ "$status" -eq 0 ]
    [ ! -e "$HANDOFF_POINTER_DIR/handoff-context-$SESSION_ID" ]
}

@test "session-pointer (leaves another session's context marker alone)" {
    mkdir -p "$HANDOFF_POINTER_DIR"
    touch "$HANDOFF_POINTER_DIR/handoff-context-other"
    run_session_pointer "$tmp"
    [ "$status" -eq 0 ]
    [ -e "$HANDOFF_POINTER_DIR/handoff-context-other" ]
}
```

Extend the two existing sweep rows in place. In *"sweeps its own long-stale
files"*, add `"$HANDOFF_POINTER_DIR/handoff-context-ancient"` to the `touch -t`
list and `[ ! -e "$HANDOFF_POINTER_DIR/handoff-context-ancient" ]` to the
assertions. In *"keeps another live session's files"*, add
`"$HANDOFF_POINTER_DIR/handoff-context-live"` to the `touch` list and
`[ -e "$HANDOFF_POINTER_DIR/handoff-context-live" ]` to the assertions.

- [ ] **Step 2: Run them to verify they fail**

Run: `bats tests/hook-test.bats -f session-pointer`
Expected: the three new rows FAIL (the marker survives), and *"sweeps its own
long-stale files"* FAILS on the new path.

- [ ] **Step 3: Clear the marker**

In `scripts/session-pointer.sh`, immediately after the `printf ... >
"$(handoff_pointer_path "$session_id")"` line:

```bash
# Re-arm the context-size nudge. It fires once per climb, gated by a marker it
# writes itself; a SessionStart is the harness-authoritative signal that the
# context was rebuilt — compact (auto-compaction included), clear, or a resume
# that restored it whole. Inferring the re-arm from a later measurement falling
# back under the threshold is the form this design rules out.
rm -f "$(handoff_context_path "$session_id")"
```

- [ ] **Step 4: Extend the sweep**

Change the `find` predicate to:

```bash
find "$HANDOFF_POINTER_DIR" -maxdepth 1 \
    \( -name 'handoff-root-*' -o -name 'handoff-drift-*' \
       -o -name 'handoff-context-*' \) \
    -mtime +7 -delete
```

Two comments claim a count and both are now wrong. The one above the `find`
says "the two names published here"; there are three. And in
`tests/hook-test.bats`, the comment heading *"never sweeps a file it does not
own"* (~line 1059) says the sweep is "scoped to the two names it publishes" —
same fix.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/hook-test.bats -f session-pointer`
Expected: all rows PASS, including the two pre-existing sweep guard-rails
(*"never sweeps a file it does not own"* and the nested-path case), which must
stay green — the widened name filter must not reach further than the new prefix.

- [ ] **Step 6: Commit**

```bash
just precommit
git add scripts/session-pointer.sh tests/hook-test.bats
git commit -m "✨ re-arm the context nudge at the next SessionStart"
```

---

### Task 3: Documentation

**Files:**
- Create: `docs/changelog/2026-08-01-context-threshold-trigger.md`
- Modify: `docs/changelog.md` (index line, newest first), `docs/design.md`,
  `CLAUDE.md`

**Interfaces:** none.

- [ ] **Step 1: Write the changelog entry**

`docs/changelog/2026-08-01-context-threshold-trigger.md`, a write-time record —
never edited afterwards. It must carry: the problem (a long turn reaches no
boundary, so `Stop` and `UserPromptSubmit` cannot see it); why `PostToolBatch`
(per assistant message; `additionalContext` verified to reach the model on the
next call of the same turn); what the trigger is *for*, now that 1M windows and
a disabled auto-compaction mean there is no wall to race — context quality and
cost; the four decisions with their rejected alternatives (halt deferred until
an ignored nudge is observed; fixed threshold over `autoCompactWindow` or a
model→window table; subagents skipped; re-arm by boundary, not by
re-measurement); and that `PostToolBatch` is undocumented, with gitlore already
depending on it. Source the reasoning from
[the spec](../../plans/2026-07-31-context-threshold-trigger-design.md) and
[the brief](../../plans/2026-07-31-context-threshold-trigger-brief.md).

- [ ] **Step 2: Add the index line**

At the top of the list in `docs/changelog.md`:

```markdown
- [2026-08-01 — Nudge the boundary at a context-size threshold](changelog/2026-08-01-context-threshold-trigger.md) — a long turn reaches no boundary; PostToolBatch is the only event that fires inside one
```

Append ` (vX.Y.Z)` only once the release lands.

- [ ] **Step 3: Rewrite the `docs/design.md` prose this invalidates**

Two edits:

1. Line 120, "Five skills, one write path, eight hooks" — there are nine today
   and this makes ten. Correct the count.
2. A new decision under `## Design decisions`:

```markdown
**The size threshold is a context-quality policy, not a race.** Non-Haiku
windows are 1M and `autoCompactEnabled` is expected off, so a growing prompt
hits no wall and no boundary the harness enters on its own. The nudge fires
because attention and cost say 150k is enough, and because the plugin can cross
that boundary carrying the task frame and a memory flush. It is a nudge and not
a halt: a halt produces no final assistant text, discards in-flight work, and
still leaves the boundary unprepared. It fires once per climb, and the re-arm
is a `SessionStart` — the harness's own signal that the context was rebuilt —
rather than a later measurement falling back under the threshold, which is the
inference this design refuses everywhere else.
[Nudge the boundary at a context-size
threshold](changelog/2026-08-01-context-threshold-trigger.md)
```

- [ ] **Step 4: Update `CLAUDE.md`**

Add `scripts/context-threshold.sh` to the script inventory in the same voice as
its neighbours, add the `PostToolBatch` line to the hooks list, correct "nine
hooks" to ten, and note the new bats rows in the Testing section (naming the two
mutation-checked negatives: the subagent skip and the marker gate).

- [ ] **Step 5: Commit**

```bash
just precommit
git add docs/ CLAUDE.md
git commit -m "📝 record the context-size threshold trigger"
```

---

## After the plan

Release is `just release` — it owns the version bump, and `version-guard.sh`
denies an agent edit to `plugin.json`'s `.version`, so no task here touches it.
A minor bump: new hook entry point, no change to the shape of either file that
crosses a boundary.

Then dogfood, which needs a restart to pick up the hook. Two things to watch:

- Whether the main transcript ever carries a subagent's `usage` entry. It
  should not — subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl` — but if it does, the
  measurement reads high and the fix is a `select(.isSidechain != true)` in the
  `jq` filter.
- Whether a nudge is ever ignored: a `usage` sample well past threshold with the
  marker already present and no `compact-continue` in the transcript. That is
  the evidence that reopens the halt.
