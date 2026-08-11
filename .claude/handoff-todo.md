## Remaining

- Add guardrails against snake_case and `name:`/filename drift, then finish
  normalising memory: the project store's `MEMORY.md` is now past Claude
  Code's 24.4KB loader cap and a hook wants it under 17.1KB — one line per
  entry, detail moved to topic files, stale/merged entries — plus the other
  tiers and the wikilink targets a link audit reports as dangling. The link
  parser must skip fenced code, or it will rewrite bash `[[ "$output" ==
  ... ]]` conditionals.
- Migrate the `micro` tier (~40 facts) once a real memory remote is settled;
  it and `general` still point at a local `./.git/gitlore-placeholder`. Then
  `gitmoji` -> `general` -> `home` -> `devddaanet` -> `skills` ->
  `candidature` -> `edify` -> `Emploi` -> `cwd-safety`.