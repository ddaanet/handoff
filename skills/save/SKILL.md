---
name: save
description: This skill should be used when the user asks to "save handoff", "save context", "prepare handoff", "before /clear", "before I clear", "write handoff", "clean handoff", "discard handoff", "clear handoff", "finalize", "wrap up", "I'm done", or otherwise signals imminent `/clear` or end-of-task. Writes a short markdown task file from a template when there is state worth preserving; removes any lingering handoff files when there is not. A Stop hook extracts session data into the composed handoff.
---

# save — Pre-Clear Task Snapshot

Preserve the minimum residual state across `/clear` — a task-scoped
pointer plus any unmade decisions — while a Stop hook handles the
mechanical extraction (last user prompts, files touched) from the
session transcript.

This skill complements Claude Code's auto-memory. Memory holds durable
facts (preferences, feedback, project context). This skill holds the
*ephemeral task frame* memory intentionally avoids.

## Protocol

Three ordered steps.

### Step 1: Update auto-memory with durable lessons

Before capturing ephemera, move any *durable* learnings from the
session into auto-memory:

- User role, preferences, expertise cues → `user` memory
- Corrections, validated judgments, rules for future sessions →
  `feedback` memory
- Project facts (deadlines, stakeholders, initiatives) → `project`
  memory
- External-system pointers (dashboards, repos, channels) → `reference`
  memory

If nothing durable surfaced this session, say so and move on. Do not
force a memory update.

Durable knowledge placed only in a handoff file is wasted — the
handoff gets overwritten on the next save. Put it in memory, where it
persists.

### Step 2: Decide save-vs-clean

Evaluate whether there is actual task state worth preserving:

- Active task with specific next steps, unmade decisions, or non-obvious
  context → **save** (go to Step 2a).
- Task already complete, abandoned, or nothing non-obvious to carry
  over → **clean** (go to Step 2b).

### Step 2a: Write the task file

Write `./.claude/handoff-task.md` following this exact template.
Create `./.claude/` if missing.

```markdown
## Current task

<ONE SENTENCE describing what was in progress. Not a recap, not a log of
what happened. What needs to resume when a fresh agent picks up. If it
runs more than one sentence, the overflow belongs in memory or git.>

## Open decisions

- <Unmade choice 1, phrased as a decision still to make, with enough
  context to decide.>
- <Unmade choice 2.>

<Leave the bullets empty or remove them entirely if there are no open
decisions. Do not invent filler.>
```

Rules:

- Do not add a top-level `#` heading — `handoff.md` provides that.
- Do not add file paths, code, or history unless a decision hinges on
  them. Mechanical context is added by the Stop hook.
- Do not write elsewhere — the Stop hook looks at this exact path.

### Step 2b: Clean up

Remove any lingering handoff files so the next session starts clean:

```bash
rm -f ./.claude/handoff-task.md ./.claude/handoff.md
```

It is correct for `save` to *remove* rather than *save* when nothing
needs handing off. Treat this as the skill's idempotent "finalize"
action.

### Step 3: Confirm

Report the action taken (saved to `handoff-task.md`, or cleaned up) so
the user knows the skill ran and what effect it had. Note that on the
next agent stop, the Stop hook will (re)generate `./.claude/handoff.md`
from the session JSONL if a task file is present.

## What the Stop hook adds

The hook runs the plugin's own `extract.py` (at
`${CLAUDE_PLUGIN_ROOT}/scripts/extract.py`, invoked automatically —
not a script to run manually), which writes
`./.claude/handoff.md` with:

- Timestamp and session ID as the top heading.
- `@.claude/handoff-task.md` reference that Claude Code expands
  recursively when the outer file is loaded.
- Last 5 real user prompts verbatim, each with a thin anchor from the
  preceding assistant turn (tool call + target, or first line of the
  response) so anaphoric prompts stay meaningful.
- Files edited or written during the session (deduplicated, ordered by
  first appearance, capped at 30).

Extraction fires on Stop only when `handoff-task.md` is newer than
`handoff.md` (or `handoff.md` is missing). No-op otherwise — so after
Step 2b cleanup, the hook correctly does nothing on subsequent stops.

## Resuming after /clear

Loading is handled by an `@.claude/handoff.md` reference in the
project's `CLAUDE.md`. Claude Code's `@` resolution recurses up to 5
hops, so the outer file pulls in `handoff-task.md` automatically. The
fresh agent sees both files' content in context from turn 1. Auto-memory
restores independently.

## Anti-patterns

- Writing a recap into `## Current task`. One sentence. If it runs
  longer, the content belongs in memory or git.
- Duplicating durable lessons into `## Open decisions`. Those go to
  feedback memory (Step 1).
- Invoking `save` when the task is done *without also cleaning up*.
  Leaving stale handoff files pollutes future sessions.
- Adding extra sections to `handoff-task.md`. The template is fixed.
  Extensions belong in memory or the repo.

## Additional resources

- **`references/design.md`** — design rationale: what the residual is
  and why the task-file + extract split exists.
