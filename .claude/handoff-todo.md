## Remaining

- Implement the checkpoint channel per
  `docs/2026-07-27-checkpoint-channel-design.md`, including inserting its
  verbatim `DESIGN.md` section before `## References`.
- Trim the closing sentence of the `without-commit` memory directive (in what
  becomes `_checkpoint-lib.sh`) once gitlore ships a release carrying `62b1e59`,
  which gives `memory-commit-batch.sh` a model channel. gitlore's latest tag is
  v0.4.1 and that commit is 14 commits past it.
