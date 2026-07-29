# Commit status excluded from the task frame (2026-06-24)

Observed defect: the routine wrap-up is `/handoff` then `/commit`. The
handoff writes `handoff-task.md` *before* the commit, so an agent that
narrates git bookkeeping ("work is uncommitted", "ready to commit") bakes
a fact that the very next routine action falsifies. The note then lands in
history (the `/commit` includes the staged task file) and is re-injected
stale at the next session's SessionStart.

This is not a sequencing problem to fix by reordering or amend-after-commit
— both fight the deliberate frozen-at-handoff semantics ([Read-time
assembly](2026-06-05-read-time-assembly.md)) and, in the reorder case, the
memory/commit dependency (gitlore needs memory clean+committed, which the
handoff turn handles). It is a *content* problem: commit/push status is
**reconstructable** state — the Status row of the residual analysis already
classifies it as "code + `git status`" (lines 69–76), and the load-time
frame injects files-touched. The task frame's job is the irreducible
residual (current task, open decisions), never git bookkeeping.

Two alternatives were rejected:

- **Reorder + amend** (commit, regenerate handoff, amend the commit):
  reopens a closed artifact, amends across the memory/code boundary, and
  breaks the paired in-history record. Machinery to make a wrong fact
  accurate.
- **Live `git status` in `load-handoff.sh`**: would make staleness
  impossible by surfacing real state at read time, but adds a git
  shell-out to a pure assembler and contradicts the stance that git status
  is the user's to read (Open questions, line 610). Scope creep for a
  content problem.

The fix is template-level, not a remembered prohibition: the `## Current
task` guidance in `SKILL.md` now frames the field as task state and
explicitly excludes commit/push status, and the Anti-patterns list names
the failure. Because the template has no slot for commit status, this is
about as reliable as the template itself — the agent fills the shape, it is
not asked to recall a ban. The legitimate case ("changed X but not
committed because tests are red") is routed to `## Open decisions` as the
*why*, not written as a status line.
