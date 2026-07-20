# precompact drives compaction — design spec

**Created:** 2026-07-18
**Revised:** 2026-07-19 — trigger architecture reworked after a TUI spike
(see "Verified TUI behavior")
**Status:** Approved design, pending implementation
**Skill affected:** `handoff:precompact`

---

## Summary

Redefine the `precompact` skill from a passive "flush memory, then *you*
run `/compact`" step into an active **commit memory → compact → continue**
driver. A human-in-the-loop operator invokes `precompact`; the skill commits
memory (via gitlore's file-trigger), authors a `/compact [directive]` plus a
continuation prompt, and arms a detached tmux watcher that drives the
compaction and resubmits the continuation so the session keeps going against
the compacted context.

This inverts two of the current skill's explicit anti-patterns
("Committing memory"; the hands-off ending) — both deliberately, because
**continuation is intrinsic**: precompact ⟹ compact ⟹ continue. `/compact`
summarises the context so the session can keep going; nobody compacts right
before a `/clear` (that discards the context compaction just paid to
summarise) or before stopping (no compaction to prepare for). If you are not
continuing, you use `handoff` + `/clear`, not precompact.

---

## Current state (to be replaced)

`skills/precompact/SKILL.md` today: flush durable learnings → run
`handoff-precompact-probe` (SDD-ledger nudge only) → "tell the user to run
`/compact`". Anti-patterns section forbids committing memory and forbids
writing task/rename files.

`scripts/memory-probe.sh` (`handoff-memory-probe`, used by the **handoff**
skill) emits the older commit path: resolve `git config gitlore.commitCommand`
and instruct the agent to run `commit-memory.sh -F -` over stdin — a Bash call.

`scripts/precompact-probe.sh` (`handoff-precompact-probe`) detects only the
superpowers SDD ledger (`.superpowers/sdd/progress.md`) and prints a
bring-the-ledger-current nudge.

---

## New behavior

### Skill body — generic, vocabulary-free

`SKILL.md` carries **no** gitlore or SDD vocabulary. It mirrors handoff's
"run the probe, follow any directive it prints, the probe owns the decision"
contract. Body:

1. If durable learnings surfaced this session, capture them in auto-memory
   now. Skip if nothing durable surfaced — do not force.
2. Run `handoff-precompact-probe` and follow any directive it prints exactly.
   Nothing printed → nothing to do. The probe owns the decision; do not
   re-derive it.
3. Decide a `/compact [directive]` (optional focus instruction; bare
   `/compact` is fine) and a **single-line** continuation prompt that resumes
   the work, and write both to `.claude/autocompact` (two lines, see format).

The **normal case** (no dirty memory, no SDD ledger) is a single silent probe
call plus a single `autocompact` write — nothing else.

The continuation prompt is authored **silently** and not reprinted in the
agent's message: the watcher types it visibly into the pane and it lands in
scrollback, so a preview in the message would be the same text shown twice
with no veto value (the watcher arms on the `autocompact` write). At most a
one-line "compaction armed" status.

### Probes — one call, composed, shared prompt text

precompact runs a **single** `handoff-precompact-probe`. That script composes
both concerns:

- **gitlore memory-commit directive** when the `gitlore-memory` submodule is
  registered (FR12) and its worktree is dirty.
- **SDD-ledger nudge** when `.superpowers/sdd/progress.md` exists.
- Both when both apply; nothing when neither.

To avoid duplicating the memory-commit prompt text between this probe and
handoff's `handoff-memory-probe`, the memory-directive logic factors into a
new sourced helper **`scripts/_probe-lib.sh`**:

- `memory-probe.sh` (`handoff-memory-probe`, handoff): calls the memory
  directive alone.
- `precompact-probe.sh` (`handoff-precompact-probe`, precompact): calls the
  memory directive, then the SDD nudge.

One authored memory-commit prompt, two composition points. handoff picks up
the migrated (file-trigger) behavior for free.

### Memory commit — migrate to gitlore's file-trigger

Replace the `commit-memory.sh -F -` Bash path with gitlore's file-trigger
(built 2026-07-16, designated **handoff-plugin-only** on 2026-07-17). The
memory directive the shared helper emits instructs the agent to:

1. Summarise pending memory changes (1–3 sentences).
2. Present the summary to the user as a **markdown blockquote** (`> …`, not a
   code fence — gitlore's hook message specifies this) and get approval. This
   is the single interactive pause of the whole precompact flow, and it exists
   only when memory is dirty. (FR11 per-commit review gate: the message file
   must not exist until the user approves.)
3. Write the approved summary to `.claude/gitlore-memory-message`.
4. Write the trigger `.claude/gitlore-commit-memory` (any content).

gitlore's `memory-commit-batch.sh` (`PostToolBatch`) then runs
`commit-memory.sh -F <msgfile>`, commits the submodule, advances local `live`,
and removes both IPC files **only on success** (a locked repo / in-flight
merge leaves them for transparent retry; clean memory clears the trigger as a
no-op). All **file writes, no Bash** — sidesteps the sandbox and the auto-mode
classifier that make `-F -` fragile.

**Path resolution** (in `_probe-lib.sh`, no reach into gitlore internals):
- message: `<superproject>/.claude/gitlore-memory-message`, where
  `<superproject>` = `git -C <mempath> rev-parse --show-superproject-working-tree`.
- trigger: `<superproject>/.claude/gitlore-commit-memory`.
Both are gitignored by gitlore already; the probe emits the resolved absolute
paths so the skill body stays vocab-free.

**Ordering falls out correct.** The agent writes the message + trigger (and
later `autocompact`) as file writes; `PostToolBatch` commits memory
immediately after that batch, while the compaction watcher only fires at
turn-end idle — so **memory commits before compaction**, with context still
full and the summary written from the un-paraphrased conversation.

### Magic file — `.claude/autocompact`

Exactly two lines (a single trailing newline tolerated); anything else is an
error:

- **Line 1** — the literal command to type: `/compact` or `/compact <directive>`.
- **Line 2** — the continuation prompt (single line: in the TUI one Enter =
  one submit, so an embedded newline would submit early — the single-line
  constraint matches how `send-keys` must work).

The file *is* "the two things to send." Line 1 carries the literal `/compact`
so the watcher types it verbatim and stays dumb. A light sanity check — line 1
begins with `/compact` — guards against garbage/cross-project misfires.

### Trigger architecture — hooks, not a mid-turn watcher

Three hooks, each firing on a harness-authoritative signal. **No hook spawns a
watcher from inside a live turn.** The empirical basis is the taxonomy below;
the short version is that prose typed mid-turn is injected into the running
turn, so a watcher that starts polling mid-turn can corrupt the very work it is
meant to preserve.

**1. `write-compact.sh` — `PostToolUse(Write|Edit)`: validate only.**

1. Match writes whose resolved path is `$cwd/.claude/autocompact` (via
   `handoff_root` + `handoff_resolve`, a **consume-time** cross-project guard —
   no separate PreToolUse guard and no activation gate, exactly like
   `autorename`; the file is ephemeral and gitignored/untracked).
2. Validate: exactly two lines, line 1 begins `/compact`.
3. On malformed content: emit a user-facing `systemMessage` **and** an
   agent-facing `hookSpecificOutput.additionalContext` naming the constraint
   that failed, so the agent can rewrite the file in the same turn instead of
   discovering the no-op at `Stop`. This is a DIRECTIVE channel, not a DENY
   channel, so the wording is imperative.
4. Never spawns, never deletes. The file must survive to `Stop`.

**2. `stop-compact.sh` — `Stop`: arm the compaction.**

Fires when the main loop has actually finished the turn — the only point at
which typing a slash command means what this design assumes.

1. No `.claude/autocompact` → silent no-op (the common case; `Stop` fires on
   every turn).
2. Rename `autocompact` → `autocompact.pending` **before** spawning, so a later
   `Stop` in the same session cannot re-arm.
3. In tmux: spawn a detached `compact-when-idle.sh` (same `setsid`/`nohup`
   detach dance as `write-rename.sh`), passing the pane id and line 1.
4. Outside tmux: emit both lines for the user to paste (mirroring
   `write-rename.sh`'s degradation) and remove the pending file.

**3. `load-compact.sh` — `SessionStart(compact)`: fire the continuation.**

`source: "compact"` is the authoritative compaction-complete signal, replacing
any pane-marker scraping.

1. No `.claude/autocompact.pending` → silent no-op (also covers auto-compaction,
   which fires the same hook).
2. Spawn a detached `continue-when-idle.sh` with line 2, then delete the pending
   file.

Line 2 is **typed as an ordinary prompt at idle**, not injected as
`additionalContext`: `additionalContext` is context, not a prompt, and cannot
start a turn. Typing it means it drains as its own turn and fires
`UserPromptSubmit` normally.

### `compact-when-idle.sh` — detached watcher (line 1)

Sibling of `rename-when-idle.sh`; reuses `_rename-lib.sh` (`is_busy`,
`is_typing`, `strip`). Usage: `compact-when-idle.sh <pane-id> <line1>`.

1. Wait until the pane is **stably idle** and the composer is empty
   (`is_typing` false). `is_typing` is load-bearing, not defensive:
   `send-keys` concatenates onto half-typed user text, which is now the
   principal corruption risk.
2. **Type-verify-submit.** Send line 1 literally with `send-keys -l` and *no*
   Enter. Capture the pane and confirm the TUI rendered command recognition (an
   autocomplete row for the command). If instead it rendered
   `No commands match "…"`, send `C-u` to clear, abort, and leave a diagnostic
   — never Enter on an unrecognized command.
3. Enter. Verify submission (line 1 left the composer); retry a few times like
   the rename watcher.
4. Exit. Completion is **not** this watcher's problem — `SessionStart(compact)`
   owns it.

Predicates must read **only the visible pane**, never `capture-pane -S`
history: a stale timer glyph in scrollback reads as BUSY long after the turn
ended (observed during the spike).

### `continue-when-idle.sh` — detached watcher (line 2)

Usage: `continue-when-idle.sh <pane-id> <line2>`. Wait for stable idle and an
empty composer, send line 2 literally, Enter, verify. No recognition check —
line 2 is prose, and prose at idle is the safe class.

---

## Verified TUI behavior (empirical basis)

Verified **2026-07-19** against **Claude Code v2.1.215**, Opus 4.8, tmux 3.5a,
by driving a throwaway `claude` session in a detached tmux session with a
logging hook on every event (spike preserved in the session scratchpad; the
plugin's own suite was untouched). These are the load-bearing facts; the
implementer should not re-derive them.

### Mid-turn input taxonomy

Typing while a turn is running does **not** have one uniform behavior. All four
rows observed directly:

| Input typed mid-turn | Behavior | `UserPromptSubmit` |
|---|---|---|
| `/focus` (TUI-local) | intercepted immediately, never queued | — |
| `/compact` (harness action) | queued → interpreted at the turn boundary | no |
| `/handoff` (plugin/skill) | queued → drains as **its own turn** | **yes** |
| plain prose | **injected into the running turn** | no |

Consequences that drive the design:

1. **Slash-shaped input is never delivered to the model as prose.** An
   unrecognized command drains to `● Unknown command: …`. The feared
   "agent hallucinates a compaction" path does not exist.
2. **Prose is the dangerous input.** It is injected into the running turn's
   next model call — confirmed by the probe session replying *"Noted your
   mid-turn message: PROBE-CONTROL-PLAIN-TEXT … I'll continue."* Line 2 typed
   mid-turn would corrupt the turn it is meant to follow.
3. **A queued `/compact` fires at the *next* `Stop`**, which may be an early
   turn boundary rather than the end of the work.

### Hook signals

4. **The chain fires in order**, with ~0.75s from `Stop` to the queue draining:
   `Stop` → `PreCompact` (+0.75s) → `SessionStart` with `"source":"compact"`
   (+47s). A queued plugin command shows the same latency: `Stop` →
   `UserPromptSubmit` (+0.76s) with `prompt` set to the raw command text.
5. **`Stop` does not fire on Esc interrupt.** An interrupted turn cannot arm the
   compaction — the fail-safe direction, for free.
6. **`Stop` payload** carries `session_id`, `cwd`, `prompt_id`,
   `permission_mode`, `effort`, `stop_hook_active`, `last_assistant_message`,
   `background_tasks`, `session_crons`.

### Pane mechanics

7. **Command recognition is visible before Enter.** Typing `/compact` with no
   Enter renders an autocomplete row with the command and its description;
   `/comzzz` renders `No commands match "/comzzz"`. Both are distinguishable in
   `capture-pane`, which is what makes type-verify-submit implementable.
8. **Busy indicator = the `[0-9]+s ·` timer** plus a randomized gerund
   (`Effecting…`, `Cogitated…`). `_rename-lib.sh`'s `is_busy` transfers
   unchanged — but predicates must read only the **visible** pane. A
   `capture-pane -S` history read matched a stale timer and reported BUSY after
   `Stop` had already fired.
9. **The tmux socket is unreachable from the agent's sandboxed Bash**
   (`error connecting to /tmp/tmux-…: Operation not permitted`), confirming the
   hook-spawned watcher as the only sandbox-clean path.

### Investigated and disproven

10. **Queued input does not bypass `UserPromptSubmit` in general.** `/compact`
    skips it because it is a harness action that never becomes a prompt, not
    because queueing suppresses hooks. A queued `/handoff` fired
    `UserPromptSubmit` with `prompt == "/handoff"` — so
    `prompt-pre-hook.sh`'s wipe works correctly when the user types
    `/handoff:handoff` at a busy session. No fix needed.

---

## Files touched

**New:**
- `scripts/write-compact.sh` — PostToolUse validator (no spawn, no delete).
- `scripts/stop-compact.sh` — `Stop` entry; arms via `autocompact.pending` and
  spawns the line-1 watcher / paste fallback.
- `scripts/load-compact.sh` — `SessionStart(compact)` entry; spawns the line-2
  watcher.
- `scripts/compact-when-idle.sh` — detached watcher, line 1, type-verify-submit.
- `scripts/continue-when-idle.sh` — detached watcher, line 2.
- `scripts/_probe-lib.sh` — shared memory-commit + SDD directive text.
- `write-compact.sh` / `stop-compact.sh` / `load-compact.sh` coverage — extend
  `tests/hook-test.bats` (path + two-line validation, malformed-file
  `additionalContext`, arm-once-only via the `.pending` rename, tmux-spawn vs
  paste fallback), matching how `write-rename.sh` is exercised.
- Watcher coverage — extend `tests/rename-test.bats` for the command-recognition
  predicate (autocomplete row vs `No commands match`) against a synthetic pane.

**Changed:**
- `skills/precompact/SKILL.md` — full rewrite: generic vocab-free body, drop
  the "tell user to run /compact" ending and the now-reversed anti-patterns;
  update `description:` frontmatter (purpose-first: commit memory + compact +
  continue).
- `scripts/precompact-probe.sh` — compose memory directive (via `_probe-lib.sh`)
  + existing SDD nudge.
- `scripts/memory-probe.sh` — slim to call the shared memory directive; drop
  the `gitlore.commitCommand` / `-F -` path.
- `hooks/hooks.json` — add `write-compact.sh` to the existing
  `PostToolUse(Write|Edit)` array (alongside `write-stage.sh`,
  `write-rename.sh`); add a new `Stop` entry; extend the `SessionStart` matcher
  to `startup|clear|compact`, dispatching `compact` to `load-compact.sh` and
  leaving `startup|clear` on `load-handoff.sh`.
- `tests/memory-probe.bats` — update for the file-trigger output.
- `tests/precompact-probe.bats` — cover the composed memory + SDD output.
- `DESIGN.md` — dated subsection recording the reversal (memory commit +
  compaction driving), superseding the two old anti-patterns; keep the
  load-bearing rationale, no deletion inventory.
- `CLAUDE.md` — component list entries for the new scripts / magic file.

`_rename-lib.sh` reused as-is (no change).

---

## Design decisions & rationale

- **Human-in-the-loop; one interactive pause.** The invocation of precompact
  *is* authorization to compact — the skill does not re-ask. The compact
  directive and continuation are quality details, not authorizations, and the
  operator sees them typed (with an interrupt window), so they are informed,
  not gated. The sole gate is the memory-commit approval, and only when memory
  is dirty — a durable git write is a different category from a prompt you can
  interrupt, and gitlore's FR11 mandates it anyway.
- **File-trigger over `-F -`.** All-file-writes sidesteps the sandbox and
  auto-mode classifier that make an agent `commit-memory.sh -F -` Bash call
  fragile. It also composes with the magic-file pattern (message, trigger,
  `autocompact` are all files a hook consumes) and orders memory-before-
  compaction naturally.
- **Hook-gated, not watcher-gated.** Both typed lines are gated on
  harness-authoritative signals (`Stop`, `SessionStart(compact)`) rather than on
  a watcher polling a live pane. A mid-turn watcher has no safe idle window to
  find: the spinner is absent during permission prompts, and prose typed into a
  live turn is injected into it. The idle-wait survives inside each watcher, but
  demoted from safety mechanism to settle delay.
- **`SessionStart(compact)` over the `⎿ Compacted (` marker.** The hook is
  authoritative and needs no pane scraping; it also covers the case where
  compaction completes too fast to observe as a busy→idle transition.
- **Type-verify-submit.** Command recognition is visible in the composer before
  Enter, so the watcher checks rather than hopes. Cheap insurance against a
  contaminated composer, which the spike identified as the residual risk once
  the hallucination path was ruled out.
- **Magic file mirrors `autorename`.** Ephemeral, consumed-on-write,
  path-checked at consume time — no PreToolUse guard, no activation gate.
- **Migrate the shared probe (not precompact-only).** handoff was left on the
  stale `-F -` path when gitlore built the file-trigger *for* handoff; one
  shared helper realigns both and closes the gap.

---

## Non-goals

- Fully unattended operation. The memory-commit approval is interactive by
  design; precompact is an attended "compact and continue," not a cron driver.
- Summarising the conversation. `/compact` does that; precompact only preserves
  what the summariser can't (durable memory, structured ledgers) and steers
  the resume.
- A `PreCompact` hook. It fires too late to author a continuation and cannot
  drive the resubmit; rejected in favor of the magic-file + watcher path.
  (`SessionStart(compact)`, which fires *after* compaction, does the
  completion-signalling job instead.)
- Driving tmux from the Bash tool. The socket is outside the sandbox (verified:
  even the test needed the sandbox disabled); the hook-spawned watcher is the
  only sandbox-clean path.
