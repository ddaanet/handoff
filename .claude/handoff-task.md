## Current task

Implementing **commit awareness** in the handoff plugin. Both memory probes
take a required `with-commit|without-commit` argument; under `with-commit` the
gitlore memory step writes only the approved summary file and never the
`.claude/gitlore-commit-memory` trigger, so memory rides the parent commit
instead of landing as a separate one. The agent supplies only the answer to
"does the request imply a commit" — the branch itself lives in code.

The approved spec at `docs/2026-07-25-commit-awareness-design.md` is the plan
of record: file-by-file scope, the two directive texts, the test matrix, and
the rejected alternatives. Read it before touching anything.

Second, older thread, untouched this session: the `memory/` duplicate and
merge-candidate sweep. Zero pairs have been confirmed so far — the one
subagent report on it was largely fabricated — and any re-run must require the
agent to confirm every cited path with `ls`/`test -f` and quote the actual
`description:` line rather than paraphrase it.

## Open decisions

- Whether to write a separate implementation plan (superpowers
  `writing-plans`) before coding, or execute the spec directly. The spec
  already names every file and the full test matrix, so a plan would largely
  restate it — but the work spans two probe scripts, one shared lib, two skill
  bodies, two bats suites, `DESIGN.md` and `README.md`, and an unplanned pass
  is where the documentation half gets dropped.
