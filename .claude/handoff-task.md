## Current task

The precompact durable-progress-probe enhancement is complete and
`just precommit`-green — no implementation remains; only the decisions
below are open.

## Open decisions

- Cut a patch release (`just release`) for this change now, or batch it
  with later work?
- Should `load-handoff.sh` emit `sessionTitle` at SessionStart to name
  the successor session (documented in the hooks reference, untested)?
  Could supplement or replace the tmux `rename-when-idle.sh` path.
  (Carried from before, still unresolved.)
