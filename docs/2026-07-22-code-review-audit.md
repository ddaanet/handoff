# Code review audit — 2026-07-22

Point-in-time record of a full-codebase review, held before cutting the
release that ships `.claude/handoff-todo.md`.

**Window reviewed:** `57b4b53..HEAD` — 126 commits since the last full review
(2026-05-21). That review covered 8 shell scripts plus `extract.py`; the tree
now has 21 shell scripts, 2 `bin/` shims and `worktree_root.py`. Of the files
it looked at, only `_lib.sh`, `_wipe-emit.sh`, `load-handoff.sh`,
`prompt-pre-hook.sh`, `skill-pre-hook.sh` and `write-guard.sh` survive, all
substantially rewritten. Diffstat over the window: 42 code files,
+4086 / −800.

**Method:** five parallel review passes — CLAUDE.md compliance, bug scan, git
history, recorded-decision adherence, comment-vs-code. The `code-review` skill
is written for a GitHub PR; this repo has never used PRs (`gh pr list
--state all` is empty), so the fetch-PR / comment-on-PR / eligibility steps had
no target and were dropped. The recorded-decision pass stands in for the
missing PR-comment history, mining DESIGN.md's dated sections and the
`feedback_*` memories instead.

Every finding below was re-verified in the main session before being recorded.
Two agent findings did not survive that check and are kept here, with the
disproof, so they are not re-raised.

## Confirmed — fix before release

### 1. A stale `autocompact` can be armed by a later, unrelated `Stop`

`_wipe-emit.sh:32-33` wipes `handoff-task.md`, `handoff-todo.md`, legacy
`handoff.md` and `autorename` — but not `autocompact`. `stop-compact.sh:23`
checks only that the file exists, with no session or recency test.

So if the file is written and validated (PostToolUse fires immediately, in the
same turn as the Write) but the turn never ends normally — Esc, a crash, or
simply quitting — the file survives on disk. The next turn that *does* end
normally arms it. That turn can be days later, in a different session, on
unrelated work, and it drives a stale `/compact <old directive>` plus a stale
continuation prompt into that conversation.

The header comment is what camouflaged this:

> Stop does NOT fire on an Esc interrupt, so an interrupted turn cannot arm
> the compaction — the fail-safe direction, for free.

True of the interrupted turn, and silent about the file outliving it. The `mv`
to `.pending` before spawning correctly blocks re-arming *within* a session,
which likely made the whole class feel handled.

**Fix shape.** Adding `autocompact` to the wipe list is not sufficient on its
own: the wipe runs on skill re-activation, which the lingering-file scenario
does not involve. Stamp a sidecar with the payload's `session_id` at validation
time in `write-compact.sh`, and have `stop-compact.sh` refuse to arm when it
does not match the current session. That leaves the agent-authored two-line
format untouched (CLAUDE.md's contract for that file) and adds no spawn and no
delete to a validate-only hook. Adding `autocompact*` to the wipe list is a
cheap complement, not a substitute.

### 2. Rename-watcher failures are silent

Found independently by two of the five passes.

- `rename-when-idle.sh:21` — `snap | is_typing && exit 0` bails with success
  when the user is composing.
- `rename-when-idle.sh:32` — bare `exit 1` after three failed verifies.
- Neither calls `watcher_fail`. `write-rename.sh:33` never exports
  `HANDOFF_FAIL_FILE`, so even a `watcher_fail` call would record nothing —
  `_rename-lib.sh:144` tolerates the unset var and exits silently.
- There is no rename-side consumer analogous to `report-compact-failure.sh`.

Both compaction watchers were retrofitted for this under the 2026-07-20
decision (`compact-when-idle.sh:26,36`, `continue-when-idle.sh:25`, with the
fail file exported at `stop-compact.sh:53` and `load-compact.sh:61`). The
rename watcher predates it and was missed. DESIGN.md:1102 names the `is_typing`
bail specifically as "the same shape [that] used to `exit 0`, indistinguishable
from success".

User-visible effect: `write-rename.sh` announces "will rename to X once idle"
and nothing ever contradicts it.

## Confirmed — cleanup

### 3. Residue from the `38992ca` session-scraping removal

- `.gitignore:9-10` ignores `.claude/handoff-error.log` and
  `.claude/handoff-session`; nothing writes either (`grep` across `scripts/
  hooks/ bin/ skills/ justfile CLAUDE.md README.md` returns zero hits outside
  `.gitignore`).
- `.claude/handoff-session` **still exists on disk** — 99 bytes, dated
  2026-07-17, holding a stale absolute path to a session JSONL. Nothing will
  ever clean it up; `_wipe-emit.sh` does not remove it.
- `.gitignore:15`'s comment attributes the `__pycache__` rule to the deleted
  `extract.py`. The rule is still needed for `worktree_root.py`; the
  attribution is not.

### 4. `CLAUDE.md:115` describes a mechanism that no longer exists

> The session pointer is NOT written here — see `write-stage.sh`.

No session pointer is written anywhere. CLAUDE.md is the stale side; its own
"Frame assembly" section describes the current read-time design correctly.

### 5. A false `set -e` rationale, verbatim in three watcher headers

`compact-when-idle.sh:12`, `continue-when-idle.sh:13`,
`rename-when-idle.sh:8`:

> No `set -e`: the sourced scaffold's `(( ))` arithmetic (wait_for_idle)
> returning 0 would abort under errexit.

It would not. `while (( SECONDS < deadline ))` is a condition and
`(( stable >= 3 )) && break` is a non-final `&&` member — both exempt from
errexit — and `wait_for_idle` ends in an explicit `return 0`. Verified by
sourcing the real `_rename-lib.sh` under `set -euo pipefail` and calling
`wait_for_idle`: rc 0, script exit 0, no abort.

Documentation-only, but a plausible-sounding false gotcha is worse than no
comment: a future edit that moves the arithmetic into an unguarded context —
where the concern *would* be real — will not be caught by anyone rechecking
against this comment.

## Rejected findings

Recorded so they are not re-raised.

**UTF-8 needle truncation** (`rename-when-idle.sh:25`). Claimed that
`head -c 20` splits a multi-byte character, so `grep -Fq` never matches even on
a successful rename, causing repeated full re-sends. Disproved: tested with a
needle deliberately ending on a bare `0xC3` continuation byte, `grep -Fq`
matches in both `C.UTF-8` (this environment's default) and `en_US.UTF-8`. GNU
`grep -F` matches byte-wise and does not reject the invalid pattern. The
reporting agent's own example title split at an ASCII boundary, so the claim
appears never to have been run.

**No mutual exclusion between watchers on one pane.** Real in principle, but
`wait_for_idle` makes a second watcher wait out the first's typing, so a double
`/handoff:autoname` applies the same rename twice rather than garbling it.
Interleaving needs a send inside the sub-second gap between `send-keys -l` and
`Enter`. Sub-threshold.

## Verified sound

Most of the surface held up, and the checks worth recording as done:

- All 11 hooks use `${CLAUDE_PLUGIN_ROOT}`; the count matches CLAUDE.md
  (2 UserPromptSubmit + 3 PreToolUse + 3 PostToolUse + 1 Stop + 2 SessionStart).
- Every hook script anchors on `handoff_root`, never raw payload `.cwd` nor
  `CLAUDE_PROJECT_DIR` directly. The probes use `git rev-parse --show-toplevel`
  instead — correct, since they are Bash-invoked by the skill body, not hooks,
  and that command returns the linked worktree's own root.
- The deny-vs-directive register split holds: guards factual with no actionable
  phrasing, probes and `write-compact.sh` correctly imperative.
- All five named bug-fixes in the window (`383c20c`, `078f030`, `4300dea`,
  `1dc008b`, `3bbcc8d`) reached every sibling call site, not just the reporting
  one. The portability fixes now exist only inside `handoff_spawn_detached`
  and `strip`.
- The `4300dea`/`1dc008b` submit-verification split is deliberate and correctly
  wired: `submit_or_fail` (is_busy) on the compact watcher,
  `submit_confirmed_or_fail` (transcript) on the continuation watcher,
  `HANDOFF_TRANSCRIPT` exported only where used.
- The `c09e5d7` consolidation preserved each caller's distinct rc-2 handling —
  only `write-guard` denies on cross-project; `read-guard` and `write-stage`
  treat rc 1 and rc 2 alike.
- gitlore coupling is IPC-filenames-only. No todo-tool name (`TodoWrite`,
  `TaskCreate`, …) appears anywhere in `scripts/`, `bin/`, `hooks/`, `skills/`.
- The `handoff-todo.md` ledger is consistently wired across frame assembly,
  wipe, both guards and both skill templates; gitignored and not force-added.
- Both skill bodies are well under the 2000-word cap (858 / 845; autoname 301).

## Planned order

1. Finding 1 — the only one that can disrupt a live session.
2. Finding 2.
3. Findings 3–5 as one cleanup commit.

`just precommit` between each; the release follows with the audit folded in.
