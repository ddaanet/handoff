## Current task

No active task — the checkpoint-channel change and the memory duplicate-pointer fix are both done.

## Open decisions

- Bump size (minor vs patch) for the checkpoint-channel change (commit 595e0f7) — deferred to release time.
- Trim the closing sentence of the without-commit memory directive in `_checkpoint-lib.sh`'s `checkpoint_memory_directive`, once gitlore ships a release carrying commit 62b1e59 — externally blocked; latest tag v0.4.1 is 14 commits behind it.