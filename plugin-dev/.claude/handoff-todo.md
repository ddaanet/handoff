## Remaining

- Execute plan Tasks 1-4: `release.sh` with `--resume`, the offline test harness and its mutation validation, the `release.just` wrappers, then docs.
- Cut toolkit 0.5.0 (plan Task 5, run by hand — network, gh auth, irreversible pushes).
- Run `just update-plugin-dev v0.5.0` in handoff, gitmoji and gitlore. handoff and gitmoji each need `prerelease: precommit` added in the same commit as the pull, or their justfiles fail to compile on arrival; gitlore already defines it.
- Check whether the consumer plugins' own justfiles have multi-line recipe doc comments, which just lists as trailing sentence fragments.
