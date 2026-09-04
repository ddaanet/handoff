## Open decisions

- The three decisions embedded in `plans/2026-09-04-checkpoint-null-no-task-file/outline.md` — applied there, but not confirmed. (1) `todo` does not follow `task`: a null `todo` keeps meaning *this call says nothing about the list*, per FR5's authored-whole versus incrementally-edited asymmetry. (2) `task` becomes required under `handoff`/`precompact` by key presence, so a forgotten field cannot silently delete a git-tracked file once null deletes. (3) `apply_task` emits a `D` manifest line only when a file was actually removed, applied to the empty-string content form as well so both stay one code path — the alternative leaves `apply_task` untouched but puts a `git add` that exits 128 into `bash-post.sh`'s stderr redirect on every rename-only call.
- Whether to run the shared `memory/MEMORY.md` compaction. The post-merge hook reports it at 95% of the 25600-byte budget, past the ~24.4KB point where Claude Code's loader silently drops the tail, so entries at the end never reach a session. `/gitlore:index-audit` is the pass for it — measure against the loader cap, relocate, retire or merge entries, then audit the diff for lost routing. Blocked on an explicit go-ahead, since it rewrites the index every ddaanet repo loads.

## Remaining

- `/proof` the outline, then `/runbook` it into phases — one tdd slice for `scripts/checkpoint.py` plus `tests/test_checkpoint.py`, inline for the two SKILL.md bodies and `docs/design.md` plus a `docs/changelog/` entry.
