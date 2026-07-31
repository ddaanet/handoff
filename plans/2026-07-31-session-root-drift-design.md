## Session root drifts silently when cwd leaves the launch repo

2026-07-31 — design. Originated as a brief written from the incident session.

### What happened

Session `f89040d0-652d-412f-854f-e47bec2ef2bd` launched in
`/Users/david/code/gitlore`. At `10:43:05Z` the session cwd moved to
`/Users/david/code/handoff` and stayed there — 110 transcript entries carry
`"cwd": ".../gitlore"`, the following 51 carry `".../handoff"`.

Everything derived from **cwd** switched at that instant: the environment
block's "Primary working directory", the `gitStatus` block, and the project
`CLAUDE.md` in context. Everything derived from **launch** did not: the
transcript directory (`~/.claude/projects/-Users-david-code-gitlore/`), the
scratchpad path, and `CLAUDE_PROJECT_DIR`.

Nothing announced the change. The agent kept reasoning from the pre-flip repo
for four turns and wrote "it belongs in handoff, not gitlore" from inside
handoff, one minute after the flip. It took the user asking "what project are
you in?" to surface it.

### What is actually wrong

Not the root policy. `handoff_root` already returns the right answer:

```
worktree_root('/Users/david/code/handoff', '/Users/david/code/gitlore')
  -> /Users/david/code/gitlore
```

`handoff` is not a linked worktree of `gitlore`, so `scripts/worktree_root.py`
walks up, hits `handoff/.git` as a *directory* (line 68), and returns
`project`. Under the rule handoff wants — the enclosing linked worktree if
there is one, else `CLAUDE_PROJECT_DIR` — that output is correct. The launch
repo is where the thread lives: the task file, the transcript, the scratchpad,
the session's identity. Following cwd would let one session leave two
`.claude/` states behind, and the second would belong to no thread.

Two things are wrong, and neither is the policy:

1. **The resolver cannot tell the caller which branch it took.** Every
   non-worktree case collapses to a bare `project`: cwd inside the project
   (line 59), cwd a foreign repo (68), cwd a linked worktree of some *other*
   project (66), cwd in no repo at all (71). The distinction exists inside the
   function and is discarded on the way out, so no caller can report drift.
2. **`handoff-checkpoint` cannot see `CLAUDE_PROJECT_DIR` at all.** It runs in
   the agent's Bash, where the variable is unset (re-confirmed 2026-07-31:
   `echo "$CLAUDE_PROJECT_DIR"` prints empty). `handoff_root` falls back to
   `$PWD`, so the writer reaches a different root than every reader.

### The consequence: the writer and the reader disagree

Observed in the incident session, in order:

```
$ handoff-checkpoint   # task.file_path = <gitlore>/.claude/handoff-task.md
handoff-checkpoint: task.file_path: must resolve to $root/.claude/handoff-task.md
$ handoff-checkpoint   # task.file_path = <handoff>/.claude/handoff-task.md
rc=0   → staged .claude/handoff-task.md .claude/handoff-todo.md
```

The checkpoint wrote and staged **handoff's** task file, while the `/clear`
that follows would have `load-handoff.sh` inject **gitlore's** — a frame from an
unrelated thread, with this session's snapshot nowhere in it. The transition
machinery is gitlore-rooted end to end (`stop-drive.sh` arms gitlore's
`autodrive`, `load-handoff.sh` consumes gitlore's `.pending`), so it would run
correctly and carry the wrong content. The clear was **not armed** for this
reason.

Collateral from the same shape: the checkpoint overwrote handoff's own
in-flight task file (the driven-transitions dogfood, stage 3) with content meant
for gitlore. Recoverable — the pre-write blob is
`d80ea85e6f8bb0be73ae4793ff45fa6a0935cb60`, 2931 bytes — but nothing warned, and
the overwrite was staged in the same act.

### Decisions

1. **`handoff_root` keeps its policy and its signature's meaning.** The
   enclosing linked worktree if there is one, else `CLAUDE_PROJECT_DIR`. No
   change to what it resolves. The handoff files stay where they are: at that
   root's `.claude/`.

2. **`worktree_root.py` also reports which branch it took.** The branches are
   already computed; label them (`inside`, `worktree`, `foreign`, `unrelated`)
   and print the label alongside the root. Detection then costs nothing:
   `handoff_root`'s bash fast path already short-circuits the two non-drift
   cases (empty cwd, cwd == project) without spawning, and every remaining call
   spawns `python3` today regardless. No new work on the every-turn path.

3. **A session-keyed pointer file bridges into the agent's Bash.** One line,
   the resolved root, at `/tmp/claude/handoff-root-<session_id>`. Not a
   preference about where handoff state lives — it is the bootstrap: the
   checkpoint cannot read a file at the project root, because addressing that
   path is the very thing it cannot do. So it goes at a path both sides can
   address blind.

   The directory is a literal, not `$CLAUDE_CODE_TMPDIR`, so the producer needs
   nothing from its environment but the session id — which every hook payload
   carries. `/tmp/claude` exists and is owner-writable.

   The consumer reads `$CLAUDE_CODE_SESSION_ID`. That variable is the harness's
   own session id: it matches the id the harness embeds in this session's
   scratchpad path and in its transcript filename, both of which are written
   per-session rather than shared. What remains unverified is the last link —
   that a hook payload's `session_id` field carries that same id. If it does
   not, the checkpoint finds no pointer and refuses (see decision 5), so the
   failure is loud rather than silently mis-rooted; first dogfood settles it.

   It holds the root and nothing else. An earlier draft had it cache the
   resolver's verdict to spare the per-turn `python3` spawn a drifted session
   incurs; that made a file written once at `SessionStart` responsible for a
   value that depends on a cwd which moves. Dropped — it optimises a state that
   should be rare and loud.

4. **Report at observation, not at the end of the turn.** Drift can be
   transient (see below), so a check that asks "is cwd foreign *now*" at some
   later gate sees nothing. `UserPromptSubmit` already resolves the root every
   turn and already owns a reporting channel (`report-watcher-failure.sh`), so
   the check rides there. Report once per observed destination — record the
   foreign root in the marker, re-report only when a different one appears — so
   a blip is announced once and a re-drift elsewhere is not swallowed.

   The `systemMessage` **begins with an ANSI style reset** so its text is not
   rendered dimmed like the ordinary hook chatter around it.

5. **A new `SessionStart` hook writes the pointer, on a wildcard matcher.** The
   write must be unconditional, and both existing loaders are gated —
   `load-handoff.sh` on the task file, `load-compact.sh` on `.pending` — so it
   is its own script rather than a preamble bolted above two gates. A wildcard
   matcher also covers `resume`, which the present table
   (`startup|clear` → `load-handoff.sh`, `compact` → `load-compact.sh`) does
   not reach at all.

   That decides the fallback: a live session always has a pointer, so its
   absence is abnormal and `handoff-checkpoint` **refuses** — exit non-zero,
   naming the missing pointer — rather than falling back to `$PWD`, which is
   today's behaviour and is silently wrong in exactly the drift case.

**Rejected**

- *Following cwd.* Two `.claude/` states per session, the second orphaned.
- *Naming the root in `load-handoff.sh`'s `additionalContext`* and having the
  skill pass it in the payload. Free, and it survives compaction
  (`load-compact.sh` re-injects) — but it puts a hand-copied path in the
  agent's hands, which is the judgement/mechanism split `CLAUDE.md` draws
  against.
- *Letting `bash-post.sh` validate or relocate after the fact.* It is the one
  component that both has `CLAUDE_PROJECT_DIR` and sees the checkpoint — but it
  fires after the write, so it can only report a file already written to the
  wrong repo, and staged in the same act.

### Evidence

**`/add-dir` does not trigger it; only a cwd move does.** Tested against the
transcript corpus and the resolver directly.

- 13 `/add-dir` invocations across 7 sessions (`gitlore/a3e2f110`, `1799332e`,
  `135235f5`; `claude-plugin-dev/5c309e98`; `handoff/6a49f6e7`, `418b085a`;
  `general/b0ca0618`). In every one, `.cwd` is identical before and after and
  stays at the launch root. The resolver's input never changes.
- Nothing in the plugin reads the additional-dirs list — no such spelling in
  `scripts/`, `hooks/` or `bin/`; `handoff_root` takes only cwd and
  `CLAUDE_PROJECT_DIR`; the hook input schema carries no such field.
- But an added dir is **not** protected. The misfire is a property of where cwd
  is, not of how a directory was registered:

  ```
  worktree_root('/Users/david/code/claude-plugins',    '<handoff>') -> <handoff>
  worktree_root('/Users/david/code/claude-plugin-dev', '<handoff>') -> <handoff>
  ```

  Both are added dirs of a handoff-launched session, both take branch
  `foreign`. `/add-dir` enlarges the set of repos a later cwd move can land in;
  it does not cause the move.

**The move is not a one-off, and it can be transient.** Session `6a49f6e7`
(launched in handoff) has cwd `handoff` throughout except `17:26:36.887Z` →
`17:26:50.996Z`, where 22 consecutive entries carry `/Users/david/code/gitlore`,
spanning four full user/assistant exchanges, then it reverts and stays.
`b0ca0618` shows the shape twice more (8 seconds to `/Users/david/xart`; and a
move to `general/tools`, a subdirectory the resolver handles correctly — branch
`inside`). What caused any of them was not determined.

A transient blip is the worse case: the writer/reader split is live for its
whole duration and nothing afterward looks wrong. It is what decides
decision 4.

### Open

- **How the branch label reaches the caller.** `worktree_root.py` is a CLI
  whose stdout `handoff_root` captures whole (`_lib.sh:256`), so a second
  printed field breaks every hook and the pytest suite. The shape that fits is
  the library's existing idiom — stdout stays the root alone, the label lands
  in a caller-scope global (`HANDOFF_ROOT_BRANCH`, like `MATCHED_NAME` /
  `DRIVE_KIND`) — and the bash fast path, which returns without invoking
  python, must set it too or callers read a stale value. Undecided.
- **`write-guard.sh` rc 2.** Under drift, a legitimate agent edit to the cwd
  repo's `handoff-todo.md` resolves outside `$root/.claude/` and is denied as
  cross-project, with no mention of the drift that caused it. Does the report
  ride there too?
- **Lifecycle.** Nothing removes `handoff-root-<session_id>`, and `/tmp/claude`
  is not swept — it holds hand-made files weeks old. One short line per
  session, so the accrual is negligible; confirm that is acceptable rather than
  leave it unsaid.
- **Tests.** bats needs a two-repo fixture (cwd in one, `CLAUDE_PROJECT_DIR`
  the other) and an override for `CLAUDE_CODE_TMPDIR`. The load-bearing
  assertions are negatives — the checkpoint does *not* write cwd's `.claude/` —
  and must be mutation-checked, not observed passing.
- **Docs and version.** Changelog entry plus the `docs/design.md` rewrite in
  the same pass; version bump.

### To probe before building

- Whether `systemMessage` honours ANSI at all (decision 4 assumes it does).

### Additional context

Evidence is reproducible from the transcript:

```sh
f=~/.claude/projects/-Users-david-code-gitlore/f89040d0-*.jsonl
jq -r '.cwd // empty' "$f" | sort | uniq -c
jq -r 'select(.cwd) | [.timestamp, .cwd] | @tsv' "$f" | awk -F'\t' '$2!=p{print; p=$2}'
```

`EnterWorktree` chdirs but does **not** move `CLAUDE_PROJECT_DIR` — which is
why `worktree_root.py` exists at all, and why `CLAUDE.md`'s rule reads "never on
`CLAUDE_PROJECT_DIR` directly (pinned to the main tree in a worktree session)".
Carried in memory as the D15 drift signal
(`ddaanet/reference_cc_worktree_memory_freeze`); measured previously, not
re-measured for this brief. See also `ddaanet/feedback_verify_session_root` —
check PWD / `CLAUDE_PROJECT_DIR` / `gitStatus` after a transition, the check
that was skipped in the incident.

The incident session could not wrap its handoff work into handoff's own task
file, because the checkpoint would write gitlore's.
