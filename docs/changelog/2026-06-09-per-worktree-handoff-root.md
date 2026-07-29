# Per-worktree handoff root (2026-06-09)

Worktree sessions must own their own `.claude/handoff-task.md`. Hooks now
anchor on `handoff_root` — the enclosing linked-worktree root derived from
on-disk `.git` linkage (`scripts/worktree_root.py`, ported from the cwd-safety
plugin), falling back to `CLAUDE_PROJECT_DIR` outside a worktree. Rejected:
trusting the raw `.cwd` field (drifts with `cd`/`/add-dir`) and recording the
root via `WorktreeCreate`/`CwdChanged` hooks (observational, no clean
per-worktree storage, fragile vs. the stateless `.git` walk). Full rationale:
`plans/2026-06-09-per-worktree-handoff-root-design.md`.
