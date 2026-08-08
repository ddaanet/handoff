## Current task

Two unreviewed design changes sit together: pass 2 of the transition state
machine (transitions become modes of the two boundary skills), and the
ledger/todo scope boundary. A code review of both is what comes next — it
was asked for before the second one landed, so it covers the pair.
`just precommit` is green: 262 bats, 11 pytest, shellcheck, ruff/mypy/ty.

Six rows are mutation-checked rather than observed passing: the held/armed
pair over one fixture, the two non-typing kinds, `handoff-approved`'s
bare-name invocation, the sweep's `held` exemption, and the retired
"must not exist" claim in the ledger boundary.

Pass 2: `held` joins the sentinel's states and the continuation line becomes
optional on both driven kinds; `skill` collapses to two values and gains
required `clear`/`compact`/`continue` fields; the checkpoint composes
`.claude/autodrive` itself and reads its own output back through
`handoff_drive_read`; `bin/handoff-approved` is the one command that leaves
`held`; `handoff-continue` and `compact-continue` are deleted.

Three deltas against `plans/2026-08-02-transition-modes-design.md`, each
deliberate and each worth a reviewer's attention. The changelog entry is
dated 2026-08-05, not the spec's 08-02, because it lands above the 08-03
entry it builds on. `context-threshold.sh` pointed at the deleted
`compact-continue` and now names `/handoff:precompact` with an explicit
"carry the compaction out" ask, since naming the skill alone would turn
every threshold crossing into a prepared compaction nobody runs.
`report-watcher-failure.sh`'s sweep now names the states it takes instead
of taking anything that is not `pending` — without it every `held` sentinel
would be discarded at the next prompt. A fourth, smaller: the other
boundary's transition field is a schema error rather than a silent ignore.

The ledger change is narrower. A live workflow ledger used to stand
`handoff-todo.md` down entirely; it now excludes only the plan's own tasks,
because the two files hold different things and only their overlap can
drift. `checkpoint_todo_suppression` became `checkpoint_todo_boundary`.

## Open decisions

- Whether to cut a release, and at what bump. Pass 2 removes two
  user-visible skill names, so it is the question the earlier minor/patch
  answer did not cover. The context-size threshold is a minor; the state
  machine and the ledger boundary ride as a patch. `just release` pushes,
  cuts a GH release and bumps the marketplace, so it waits for an explicit
  yes.
- Whether to route `autoname` through `handoff-checkpoint`, making the
  checkpoint the sole writer of the sentinel and collapsing
  `write-drive.sh` into a `write-guard.sh` deny. Recorded as a deliberate
  third pass in the state-machine spec's rejected alternatives, not
  refused.
- Whether the main session transcript ever carries a subagent's `usage`
  entry. It should not — subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl` — but if it does the
  measurement reads high, and the fix is a `select(.isSidechain != true)`
  in the `jq` filter.
- Whether the pointer sweep's guard-rail deserves a `handoff-`-prefixed
  foreign file. Its fixture uses `somebody-elses-file`, so it catches a
  filter widened to everything but not one widened to any name this plugin
  might publish.