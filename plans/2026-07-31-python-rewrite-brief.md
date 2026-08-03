## Brief: split the scripts by language along the hot/cold line

2026-07-31 — target repo: `handoff`

The shell scripts total 1696 lines and some have outgrown bash. This is not a
wholesale rewrite: interpreter startup is real on the event-hook paths and
irrelevant on the once-per-boundary ones, so the split follows that line.

### Decisions

- **Convert to Python:** `checkpoint.sh` + `_checkpoint-lib.sh` (507 lines) and
  `drive-when-idle.sh` + `_watcher-lib.sh` (298 lines). The first does JSON
  schema validation, string-replacement edits and directive composition — bash's
  worst fit, which is why it already delegates the Edit form to a `python3`
  heredoc. The second is retry loops, transcript JSONL parsing and pane
  predicates, running detached with timeouts up to 300 s. Both run once per
  boundary.
- **Keep in bash:** the six event hooks — `bash-post.sh`, `write-guard.sh`,
  `write-stage.sh`, `write-drive.sh`, `stop-drive.sh`,
  `report-watcher-failure.sh` (310 lines total). Each is a jq parse, a
  comparison and an exit, on a path that fires constantly.
- **`_lib.sh` stays bash.** Its hot callers are the event hooks. Cold helpers
  migrate with their callers; `handoff_root`, `handoff_match_target` and
  `handoff_resolve` do not.
- **`checkpoint_is_empty_body` stays shared across the seam.** It is
  deliberately common to `checkpoint.sh` and `write-stage.sh` so the two writers
  cannot disagree about what counts as empty. `write-stage.sh` is hot, but that
  predicate runs only after the basename and path match — on the cold branch,
  for a `handoff-todo.md` write. It can pay a spawn there without touching the
  hot path.
- **Sequencing: after the drift work** (`plans/2026-07-31-session-root-drift-design.md`).
  That change touches `worktree_root.py`, already Python, and adds one small
  `SessionStart` hook plus one read in the checkpoint. Small against the current
  code; churn against a rewrite in flight.

### Constraints

- Measured on the dev droplet, 2026-07-31, `nproc` = 2 (David resizes it 1↔2 to
  save cost, so assume 1): bare `python3` 31.6 ms per spawn, `python3` with
  `import json, os, sys` 52.6 ms, the current bash + `jq` shape 8 ms. About a
  45 ms tax per invocation.
- NFR2: `bash-post.sh` fires on every Bash call in every session with the plugin
  installed. NFR1 still holds — no git or tmux work from the agent's sandboxed
  Bash.
- Both test harnesses already exist: bats for the shell, pytest for the Python
  (`uv sync`, direnv-activated venv, bare `pytest`). Converting adds no new
  tooling.
- `hooks/hooks.json` invokes hooks as `bash ${CLAUDE_PLUGIN_ROOT}/scripts/…`;
  converted entry points change that line and the `[ -x ]` assumption with it.

### Rejected approaches

- **Python all over.** Puts 45 ms on every Bash call and every Write/Edit, on a
  1–2 vCPU box, to clean up 310 lines that are already thin. The tax is worst
  exactly where the code is simplest.
- **Leaving it all in bash.** `checkpoint.sh` validating a JSON schema in shell
  is the case that motivated this, and it already loses — it delegates the hard
  part to `python3` today.

### Additional context

The codebase has been converging on this split already: `handoff_resolve` shells
out to python for path canonicalization, `worktree_root.py` is python, the
checkpoint's Edit form is a python heredoc. In every case bash is the gate and
python is the work, with the spawn deferred behind a cheap match. This finishes
a half-built pattern rather than introducing one.

Per `CLAUDE.md`, a design change lands a `docs/changelog/` entry plus its index
line and rewrites whatever `docs/design.md` prose it invalidates, in the same
pass. Changing a script's language does not change the shape of
`handoff-task.md` or `handoff-todo.md`, so it is not a breaking change on that
count — but the hook entry points move, which is a version bump.
