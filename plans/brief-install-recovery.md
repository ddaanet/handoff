## Brief: handoff plugin — install recovery (gitlore analogy)

2026-05-29

### Background — the gitlore pattern

Gitlore 0.2.3 added "install recovery" to its `/gitlore:install` script
(`scripts/install/run.sh`). After a successful install, it checks for the
old Claude Code project-scoped auto-memory directory
(`~/.claude/projects/<encoded-project-path>/memory/`) and replaces it with a
stub `MEMORY.md` explaining that memory now lives in the gitlore submodule.
The helper lives in `scripts/lib/util.sh`:

- `gitlore_cc_memory_dir <toplevel>` — computes the path by encoding the
  repo root (non-`[A-Za-z0-9]` → `-`).
- `gitlore_mark_migrated <dir>` — idempotent; if stub not present, does
  `rm -rf <dir>` + creates `<dir>/MEMORY.md` with an explanatory message.

The call site in `run.sh` is a simple guard after the hook wiring:
```bash
_old_memory=$(gitlore_cc_memory_dir "$toplevel")
if [ -d "$_old_memory" ]; then
  gitlore_mark_migrated "$_old_memory"
fi
```

### Task

Add analogous install recovery to the **handoff** plugin. The specifics of
what constitutes "stale state" and where recovery should live are defined by
the user — this brief records the codebase context needed to implement it
without re-exploring the repo.

### Handoff repo layout (~/code/handoff)

Key files:
- `scripts/load-handoff.sh` — `SessionStart(startup|clear)` hook; loads
  `.claude/handoff.md` into the agent context. Currently the closest thing
  to an install/setup hook.
- `scripts/_lib.sh` — shared helpers: `HANDOFF_REL_*` path constants,
  `handoff_resolve()` (Python-based portable `realpath`),
  `handoff_activated()` (transcript scraper), `handoff_deny()`.
- `scripts/write-guard.sh` — `PreToolUse(Write|Edit)`; blocks agent writes
  to hook-owned files before activation.
- `scripts/read-guard.sh` — `PreToolUse(Read)`; blocks reads of
  `handoff.md` always, `handoff-task.md` before activation.
- `scripts/write-extract.sh` — `PostToolUse(Write|Edit)`; regenerates
  `.claude/handoff.md` after `handoff-task.md` is written.
- `scripts/extract.py` — deterministic parser; reads the session JSONL
  and writes `handoff.md` (inlined task + extracted sections).
- `hooks/hooks.json` — declares all six hooks; uses
  `${CLAUDE_PLUGIN_ROOT}` for portability.
- `.claude-plugin/plugin.json` — version 0.4.1.

There is **no install command** in handoff today. All hooks are stateless
and fire on every session. Any recovery/setup that needs to run exactly once
on plugin install or upgrade has no existing entry point.

### Canonical output paths

Defined as constants in `_lib.sh`:
```
HANDOFF_REL_TASK=".claude/handoff-task.md"
HANDOFF_REL_OUT=".claude/handoff.md"
HANDOFF_REL_ERR=".claude/handoff-error.log"
```
Changing these is a breaking change requiring a version bump.

### Testing

```
just precommit        # lint manifests + shellcheck
just hook-test        # end-to-end hook tests (synthetic payloads)
just extract-test     # fixture-driven extract.py tests
just smoke            # run extract.py against most recent session JSONL
```

All test scripts are in `tests/`. Add new scenarios to existing files,
not new just recipes.

### Constraints

- Hooks must be mechanical and cwd-scoped. Judgement belongs in the skill.
- `jq` is available (unlike gitmoji). `python3` is available and preferred
  for portable path ops (`handoff_resolve` pattern).
- Plugin is in active use; any recovery must be idempotent and silent
  when nothing to do.
- ShellCheck `-x` is enforced; sourced files need
  `# shellcheck source-path=SCRIPTDIR source=<file>.sh`.
