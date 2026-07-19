# precompact drives compaction — design spec

**Created:** 2026-07-18
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

### `write-compact.sh` — new `PostToolUse(Write|Edit)` hook

Mirrors `write-rename.sh`:

1. Match writes whose resolved path is `$cwd/.claude/autocompact` (via
   `handoff_root` + `handoff_resolve`, a **consume-time** cross-project guard
   — no separate PreToolUse guard and no activation gate, exactly like
   `autorename`; the file is ephemeral, gitignored/untracked, consumed on
   write).
2. Read the two lines; validate (exactly two lines, line 1 begins `/compact`).
   On malformed content: emit a `systemMessage` and no-op.
3. Delete the file.
4. In tmux (`$TMUX` + `$TMUX_PANE` set): spawn a detached
   `compact-when-idle.sh` via `setsid`/`nohup` fallback (same detach dance as
   `write-rename.sh`), passing the pane id and the two lines. Emit a curt
   `systemMessage` ("will compact once idle …").
5. Outside tmux: emit both lines for the user to paste, in
   `hookSpecificOutput.additionalContext` + a user-facing `systemMessage`
   (mirroring `write-rename.sh`'s degradation).

### `compact-when-idle.sh` — new detached watcher

Sibling of `rename-when-idle.sh`; reuses `_rename-lib.sh` (`is_busy`,
`is_typing`, `strip`). Usage: `compact-when-idle.sh <pane-id> <line1> <line2>`.

1. Wait until the pane is **stably idle** (`is_busy` false for ~3 consecutive
   polls, up to a timeout) — readiness is *not* the `❯` glyph (see verified
   findings). Never type over a prompt the user is editing (`is_typing`).
2. Send line 1 literally (`send-keys -l`), then `Enter`. Verify it submitted
   (input cleared / line 1 left the input); retry a few times like the rename
   watcher.
3. Wait for the **`⎿ Compacted (`** marker to appear in the pane (generous
   timeout). This is the compaction-complete signal — **not** busy-polling,
   because compaction can be too fast to catch as busy (verified).
4. Send line 2 literally, then `Enter`. Verify submitted.

The watcher never depends on a queued message surviving compaction's context
swap: line 2 is sent only after the `Compacted` marker, so it lands as a fresh
idle submit against the compacted context. (Input-during-busy queuing is a
safety net, not a dependency — see findings.)

---

## Verified TUI behavior (empirical basis)

Verified this session against **Claude Code v2.1.214**, Haiku 4.5, tmux 3.5a,
by driving a throwaway `claude` session in a private tmux socket (snapshots in
the session scratchpad). These are the load-bearing facts; the implementer
should not re-derive them:

1. **Input during any busy operation is queued, not interrupted or merged.**
   Typing + Enter while a turn (or compaction) runs shows "Press up to edit
   queued messages"; the queued text runs as its own turn afterward. Esc
   interrupts; typing does not.
2. **Readiness ≠ the `❯` glyph.** The prompt glyph appears while the backend
   still shows `/rc connecting…`; keystrokes/Enter sent then do **not** submit.
   Must wait for a stable connected-idle state (what `rename-when-idle.sh`
   already does).
3. **Busy indicator = the `(<n>s ·` timer** plus a randomized gerund
   (`Frolicking…`, `Fiddle-faddling…`, `Effecting…`). `_rename-lib.sh`'s
   `is_busy` greps `\([0-9]+s ·|esc to interrupt` — the timer clause still
   matches this version. The predicate transfers unchanged.
4. **`/compact <directive>` submits via `send-keys -l` + `Enter`** and
   triggers real compaction: the pane shows `⎿ Compacted (ctrl+o to see full
   summary)` and the `SessionStart:compact` hooks fire.
5. **Compaction can be too fast to catch as "busy"** (≈40k context on Haiku
   compacted between 0.2s polls). The reliable completion signal is the
   `⎿ Compacted (` marker line, not a busy→idle transition.
6. **A continuation sent after the marker runs against the compacted
   context** — verified by a correct answer sourced from the retained summary.

---

## Files touched

**New:**
- `scripts/write-compact.sh` — PostToolUse entry, spawns the watcher / paste
  fallback.
- `scripts/compact-when-idle.sh` — detached watcher.
- `scripts/_probe-lib.sh` — shared memory-commit + SDD directive text.
- `write-compact.sh` coverage — extend `tests/hook-test.bats` (path /
  two-line validation, tmux-spawn vs paste fallback), matching how
  `write-rename.sh` is exercised.
- `compact-when-idle.sh` predicate/marker coverage — extend
  `tests/rename-test.bats` for the `Compacted`-marker wait against a synthetic
  pane.

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
  `write-rename.sh`).
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
- **Marker-gated continuation.** Gating line 2 on the `⎿ Compacted (` marker
  avoids depending on queue-through-compaction (the one behavior not verified:
  a queued message surviving the context swap). Queuing remains a safety net
  if timing slips.
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
- Driving tmux from the Bash tool. The socket is outside the sandbox (verified:
  even the test needed the sandbox disabled); the hook-spawned watcher is the
  only sandbox-clean path.
