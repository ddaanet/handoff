# 2026-08-10 — checkpoint.sh and the watcher move to Python

The full write-time record — the constraints, the rejected alternatives, the
sequencing decision — is
[`plans/2026-07-31-python-rewrite-brief.md`](../../plans/2026-07-31-python-rewrite-brief.md).
This entry is what changed and why.

## The defect

`checkpoint.sh` + `_checkpoint-lib.sh` (JSON schema validation, Write/Edit
form application, manifest writing, directive composition) and
`drive-when-idle.sh` + `_watcher-lib.sh` (retry loops, transcript JSONL
parsing, pane predicates) had outgrown bash: `checkpoint.sh` already
delegated its Edit form to a `python3` heredoc because string-replacement
editing in shell is unworkable, and both files were doing bash's worst work
— structured data, not text streams. Both run once per boundary, not on a
hot path, so the interpreter-startup tax the brief measured (about 45ms on
the dev droplet) is paid where it is cheapest to pay.

## What changed

`scripts/checkpoint.py` + `scripts/_checkpoint_lib.py` replace
`checkpoint.sh` + `_checkpoint-lib.sh`; `scripts/drive_when_idle.py` +
`scripts/_watcher_lib.py` replace `drive-when-idle.sh` + `_watcher-lib.sh`.
All four old bash files are deleted outright, not kept as dead weight.

The six event hooks that fire on every tool call — `bash-post.sh`,
`write-guard.sh`, `write-stage.sh`, `stop-drive.sh`,
`report-watcher-failure.sh`, `inject-checkpoint-root.sh` — stay bash, per
the brief's hot/cold line. `_lib.sh` stays bash too: its callers are those
same hot-path hooks, and `handoff_root`, `handoff_match_target`, and
`handoff_resolve` have no reason to move.

`checkpoint_is_empty_body` (renamed `is_empty_body`) crosses the seam: it
moved to `_checkpoint_lib.py`, called in-process from `checkpoint.py` and via
a `python3 _checkpoint_lib.py --is-empty-body` subprocess spawn from
`write-stage.sh`, which stays bash. The brief accepted paying a spawn there
because the call sits behind `write-stage.sh`'s basename/path match — the
cold branch, only reached for a `handoff-todo.md` write, never on every tool
call.

Wiring: `bin/handoff-checkpoint` execs `checkpoint.py` directly rather than
`checkpoint.sh`. `_lib.sh`'s `handoff_spawn_detached` picks `python3` or
`bash` by the target script's extension, so `stop-drive.sh`,
`load-compact.sh`, and `load-handoff.sh` — all three spawners of the
detached walker — needed no changes beyond the filename they pass in.
`hooks/hooks.json` and the `justfile`'s test recipes were updated for the
new entry points.

Tests: `tests/checkpoint.bats` is trimmed from covering all of
`checkpoint.sh` to the rows that test what stayed bash —
`inject-checkpoint-root.sh`, `bin/handoff-approved`, the `bin/`
shim, and `bash-post.sh`. `tests/watcher-test.bats` is deleted outright, not
trimmed — every row it held ported to pytest. The bash-side behavior these
two files used to share, like the empty-body predicate, is exercised through
`_checkpoint_lib.py --is-empty-body` from the bash side and directly from
the Python side, never duplicated. New: `tests/test_checkpoint.py` (89
tests), `tests/test_drive_when_idle.py` (18 tests, end-to-end against the
tmux stub via subprocess), `tests/test_watcher_lib.py` (21 tests), and a
shared `tests/conftest.py` for the `TmuxStub` fixture the watcher tests use.
Full suite: `bats tests/*.bats` 283/283, `pytest` 150/150, `just precommit`
clean end to end (shellcheck -x, ruff, ruff format, docformatter, mypy
--strict, ty, both bats suites, pytest).

## Not done here

`plugin.json`'s version is unchanged — `version-guard.sh` blocks a direct
agent edit, and the bump for this breaking change (the hook entry points
moved) happens at `just release` time, not as part of the conversion.
