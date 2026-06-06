## Current task

Resume subagent-driven-development execution of `docs/superpowers/plans/2026-06-05-read-time-handoff-assembly.md` on branch `feat/read-time-assembly`: Task 4 (`load-handoff.sh`) is implemented but needs spec + quality review, then Tasks 5–7 (slim staging hook, drop `handoff.md` guards, smoke/version/docs).

## Open decisions

- Task 4 review pending: spec reviewer should check that `load-handoff.sh` gates on task file, reads pointer, calls `extract.py` stdout, uses `${#assembled}` for size, and task file mtime for age. Quality reviewer should check error handling and `--arg` vs `--rawfile` justification.
