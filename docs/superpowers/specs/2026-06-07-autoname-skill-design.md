# autoname skill — Design

Date: 2026-06-07.

## Problem

handoff names the session as a byproduct of its flow: the `handoff:handoff`
skill writes the title as the sole line of `.claude/autorename` in the same
turn it writes the task file, and the `write-rename.sh` PostToolUse hook
drives the actual `/rename`. There is no way to *only* name the session
without invoking the whole handoff flow (task-snapshot judgment, memory
write, `handoff-task.md`).

The motivating case is a `/btw` side conversation: a branch that runs
alongside a still-live main thread. Such a session may be worth naming, but a
handoff is wrong for it — nothing is being `/clear`'d, the main thread
continues, and there is no residual task to carry across a boundary. It wants
the rename, not the snapshot. Reusing the new skill from handoff would buy
nothing and cost handoff an extra turn, so handoff keeps naming itself
inline.

## Goal

Ship a standalone `/handoff:autoname` skill that names the current session
and nothing else. It is handoff's rename-half, extracted as its own
invocable skill, backed by the rename mechanics already in the plugin.

## Mechanism

The live rename path is already in place and is **not** gated on handoff
activation:

> Write `.claude/autorename` (one line = title) → `write-rename.sh`
> (`PostToolUse(Write|Edit)`) resolves the path, reads the title, deletes
> the file, and either spawns `rename-when-idle.sh` (in tmux) or emits a
> `/rename …` paste line (outside tmux).

`write-rename.sh` keys on the resolved path `$cwd/.claude/autorename`, so any
write that lands there triggers the rename — handoff's write and autoname's
write are indistinguishable to the hook. Running the rename via the hook
(rather than calling a script over the Bash tool) is deliberate: it keeps the
tmux socket reachable with no sandbox bypass.

Therefore autoname needs **no new scripts and no new hooks** — only a new
`skills/autoname/SKILL.md`.

### Skill behavior

1. Decide a concise session title from the conversation, making **no tool
   calls** — same rules handoff already uses: ≤ ~50 characters, Title Case,
   no surrounding quotes, no trailing punctuation. The title is always
   auto-derived; the skill takes no argument (an explicit title would just
   be a worse `/rename`).
2. Issue a single `Write` of that title as the sole line of
   `.claude/autorename`.
3. If the resulting hook `systemMessage` carries a `/rename …` line (the
   non-tmux fallback), relay it in a fenced code block so the user can paste
   it — the same instruction handoff's `SKILL.md` already carries.

### Frontmatter / triggers

Third-person description with trigger phrases for the name-only case:
"name this conversation", "name this chat", "rename session", "rename this
session", "title this session", "autoname". Deliberately excludes the
handoff/`/clear`/"wrap up"/"finalize" phrases so the two skills stay
disjoint — autoname never implies a handoff and handoff never routes through
autoname.

## Relationship to handoff

- handoff is unchanged. It keeps writing `.claude/autorename` inline during
  its own flow — no extra turn, no dependency on autoname.
- Both skills write the same trigger file. That is a shared *mechanism*, not
  a call graph: neither skill invokes the other.
- autoname does **not** touch memory, `handoff-task.md`, or the session
  pointer. It is rename-only.

## Vestigial cleanup: remove `set-title.sh`

`scripts/set-title.sh` is the older agent-callable entry point for session
naming (run over the Bash tool). It is wired nowhere in `hooks.json`, the
handoff skill does not call it, and its only remaining references are its own
tests and the CLAUDE.md docs. Its documented role — "skill entry point for
session naming" — is exactly what autoname now fills via the file+hook path,
which also avoids the tmux-socket sandbox problem that an over-Bash call
would hit. Remove it as part of this work:

- delete `scripts/set-title.sh`;
- drop its branches from `tests/rename-test.sh` (the missing-title and
  not-in-tmux cases — `_rename-lib.sh` predicates and `rename-when-idle.sh`
  end-to-end coverage stay);
- remove its bullet and the two stray `set-title.sh` mentions from
  `CLAUDE.md`.

`rename-when-idle.sh`, `_rename-lib.sh`, and `write-rename.sh` are untouched.

## Testing

No new mechanical tests. The rename hook path (`write-rename.sh` +
`rename-when-idle.sh`) is already covered by `tests/rename-test.sh`, and the
new skill is pure prose with no script of its own — nothing new to assert.
`just precommit` must stay green after `set-title.sh` and its test branches
are removed.

## Documentation

- Add the `autoname` skill to the "Skill: handoff" section of `DESIGN.md`
  (it now ships two skills) and note the rename-half extraction.
- Add a `skills/autoname/SKILL.md` bullet and remove the `set-title.sh`
  bullet in `CLAUDE.md`'s layout list.
- README: mention `/handoff:autoname` as the name-only entry point.

## Non-goals

- Reusing autoname from handoff. Explicitly rejected — no benefit, one extra
  turn.
- Renaming the `.claude/autorename` trigger file to match the skill name. It
  is a machine-local internal contract consumed by `write-rename.sh`;
  churning it buys nothing.
- Any argument / explicit-title mode. autoname always auto-derives.
