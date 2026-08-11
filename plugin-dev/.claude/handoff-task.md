Three toolkit briefs (shared-claude-import, marketplace-writability-preflight, exclude-memory-submodule) are done. Next: release this toolkit, then propagate the new version into the 8 sibling consumers that vendor it.

## Open decisions

- Version bump size for `just release`: all three changes are bug fixes / a convention import, no breaking changes — patch is the default reading, but confirm before running.
- For each of the 8 sibling consumers (gitmoji, onekeys, gitlore, shell-gotchas, cwd-safety, handoff, unsandbox-git-status, candidature): check whether their untracked `brief-plugin-dev-0.5.0.md` still exists and whether that consumer has already upgraded past 0.5.0. Drop the brief if so; otherwise update it to reference the version this release produces.
