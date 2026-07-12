## Current task

Release the pending plugin changes — compact-summary extractor fix,
new `/handoff:precompact` skill, `.bin/claude` dev launcher shim —
via `just release` (patch bump).

## Open decisions

- Whether `load-handoff.sh` should emit `sessionTitle` in its
  SessionStart output (documented in the hooks reference, untested) to
  name the successor session at load time — could supplement or
  replace the tmux `rename-when-idle.sh` path.
