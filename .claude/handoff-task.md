## Current task

Nothing in flight — the 0.11.3 release closed the thread out. One
unexplained signal is worth carrying: a single `just precommit` exited 1
at the `bats` line with the full 154-test TAP stream present and zero
`not ok` lines. Seven bats runs and three full precommit runs since have
been clean, so it is unreproduced rather than fixed. If it recurs, the
thing to capture is bats' **stderr** — the TAP output itself was
complete and passing, so the failure originates outside the test results.

## Open decisions

- Whether the reverted memory line stands. An uncommitted re-add of
  `- [self-contained directives](ddaanet/feedback_self_contained_directives.md)`
  was dropped from `memory/MEMORY.md` (line 18 already carried it) and
  `memory/ddaanet/MEMORY.md` (line 33 already carried it), to clear the
  submodule so `just release` could run. It was a verbatim duplicate and
  the shape gitlore later refuses as a duplicate pointer path — but
  David has not seen that diff and may want it back.
