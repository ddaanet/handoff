# 2026-07-31 — The pointer directory sweeps itself

The two items
[the drift change](2026-07-31-session-root-drift.md) left open, settled before
it shipped. One turned out not to exist; the other got a mechanism.

## `write-guard.sh` rc 2: the premise was wrong

The open item read "a legitimate agent edit to the cwd repo's
`handoff-todo.md` is denied as cross-project". `write-guard.sh` does not guard
that file. It guards `handoff-task.md` alone, and has since
[one channel, one writer](2026-07-27-one-channel-one-writer.md) made the todo
list agent-editable (FR4). A drifted edit to `handoff-todo.md` reaches
`write-stage.sh`, whose `handoff_match_target … || exit 0` treats rc 2 exactly
like rc 1: nothing is denied, nothing is staged, and nothing is said.

What rc 2 actually covers is a Write or Edit to a `handoff-task.md` that
resolves somewhere else — a file the agent may not write under any
circumstances (FR3), which the next line denies anyway. Both branches end in a
deny; only the sentence differs, and rc 2's already prints `resolved:` and
`expected:`, which *is* the split, stated as two concrete paths.

So: no change. Drift keeps one reporting owner.
`report-watcher-failure.sh` reports once per episode and its
`additionalContext` already says that every handoff file is under the root; a
second producer at `PreToolUse` would speak per write, and would then need to
coordinate on the episode marker not to — a guard around a singleton that is
already modelled as one.

The item did surface something real, and it survives untouched: under drift an
agent edit to `.claude/handoff-todo.md` lands in the drifted repo and is
silently not staged. That is not wording in `write-guard.sh`. It is what the
drift report is for, and the report fires at the first turn of the episode,
ahead of any such edit.

## Lifecycle: the producer sweeps, on the way in

Neither `/tmp/claude/handoff-root-<session_id>` nor `handoff-drift-<session_id>`
has an owner that outlives the session. The pointer is published at
`SessionStart` and read by the agent's Bash; the drift marker is written by the
report hook and cleared only if the cwd comes back. A session ends without
either being told, and the directory is a shared literal path that nothing
sweeps — it holds hand-made files weeks old.

`session-pointer.sh` now sweeps its own leavings, immediately after publishing.
One `find`, `-mtime +7`, scoped by name to the two files it writes and by
`-maxdepth 1` to the one level it writes them at. It runs once per session
start, which is the only moment anything of this plugin's runs in that
directory, and it runs *after* the write, so this session's own pointer is
fresh whatever the threshold.

The threshold has a cost, and it is the honest one: a session that stays open
seven days without any `SessionStart` — no resume, no clear, no compaction —
loses its pointer while still live. The failure is loud and self-correcting,
since the checkpoint refuses by naming the restart that republishes one.

## Rejected

- *A `SessionEnd` hook that removes both.* The end that leaves a file behind is
  the abnormal one — a crash, a kill, a quit that fires nothing — so the hook
  would clean up exactly the cases that do not need it, and add a hook event to
  the plugin's surface for janitorial work.
- *Leaving it to the operating system.* `/tmp` sweeps are per-machine policy
  (`systemd-tmpfiles` intervals, macOS's three-day rule), and the observed state
  of this directory is that nothing sweeps it. A plugin that leaves files
  forever unless the host happens to be configured to notice is not choosing a
  lifecycle, it is declining to.
- *Refreshing the pointer's mtime every turn from `UserPromptSubmit`.* Liveness
  would then be exact, and the seven-day trade above disappears. But it adds a
  second writer to a file with one owner, and a write on every turn of every
  session, to protect a case that needs a session idle for a week.
- *A shorter threshold.* Nothing is gained: the files are one line each, and the
  only thing a stale one costs is an inode. The threshold exists to bound
  accumulation, not to reclaim anything.
