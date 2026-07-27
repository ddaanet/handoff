## Current task

`docs/2026-07-27-checkpoint-channel-design.md` specifies collapsing the wrap-up
into one `handoff-checkpoint` CLI that takes a schema-validated JSON payload on
stdin, replacing the activation wipe, three Write calls, the activation
predicate and both probes. It carries the verbatim `DESIGN.md` section to insert
before `## References`. The design is settled and approved section by section;
no code has changed yet.

## Open decisions

- Bump size for the checkpoint change. It rewrites the skills' invocation
  contract and deletes five scripts, but no output path moves and both skills
  keep their names — minor or patch. The release recipe owns `.version`; only
  the size is open. It ships together with the already-committed
  ledger-liveness change, which on its own was judged not worth a release.
