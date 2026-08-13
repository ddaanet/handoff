## Remaining

- Compact `memory/MEMORY.md`. It is at 24.3KB against Claude Code's
  24.4KB loader cutoff, so entries past the tail silently never reach a
  session. Retire or merge stale entries to get under 17.1KB — never
  shorten a trigger to hit the number, since an unroutable line is worse
  than a dropped one.
