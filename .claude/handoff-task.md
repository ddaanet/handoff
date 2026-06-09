## Current task

Execute the 6-task TDD plan in `plans/2026-06-09-per-worktree-handoff-root-plan.md` via subagent-driven development — it adds `scripts/worktree_root.py` + a `handoff_root` wrapper in `_lib.sh`, then routes every cwd-scoped hook through it so worktree sessions resolve to their own `.claude/`.

## Open decisions

- Empty-cwd guard in `worktree_root.py` (`if not cwd: return project`): keep (recommended — makes the resolver total + CWD-independent, and the existing cwd-less `load-handoff` bats scenarios exercise it) or drop (I told the user "dropping it" during design, but the tests showed it's load-bearing). Resolve at Task 1.
- Commit the spec + plan standalone now, or let them ride in the Task 6 docs commit as the plan currently specifies.
