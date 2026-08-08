# autoname through the checkpoint — one writer for the sentinel

Third pass of the transition work, recorded as a rejected alternative in
`plans/2026-08-03-transition-state-machine-design.md` and deferred there
because it alters `autoname`'s contract. It is that change, on its own.

## The defect

`.claude/autodrive` has two producers. `checkpoint.sh` composes it from the
payload's transition fields and reads its own output back through
`handoff_drive_read`, so composer and parser cannot drift. `autoname` writes it
with the `Write` tool from a three-line template in its skill body, and
`write-drive.sh` validates that write at `PostToolUse` — a second parser
position, a second set of failure messages, and a rule (`the agent writes only
armed`) that exists solely because an agent holds the pen.

The template in the skill body is the drift surface. `checkpoint.sh:126-131`
already composes exactly the sentinel `autoname` writes, under
`skill: "handoff"` with `clear: false`, and says so in a comment. Two producers
of one artifact, one of them a prose template in a file nothing validates
against the parser.

`autoname` also addresses the file as `./.claude/autodrive` — relative to the
session cwd. Every other writer resolves the root from the session pointer
precisely because cwd drifts; `autoname` is the one path that still writes
wherever the shell happens to be, while every reader stays at the root.

## The change

`skill` takes a third value, `autoname`. Its payload is two fields:

```json
{"skill": "autoname", "rename": "<title>"}
```

`task`, `todo`, `clear`, `compact`, `continue` and `commit` are each a schema
error under it, exactly as `rename` is under `precompact`. The rule the schema
already follows is that a field is required where it carries a judgment and
forbidden where it would be a silent no-op; `autoname` makes no commit-awareness
decision, no transition decision and no continuation decision, so it carries no
field for one.

`checkpoint_memory_directive` moves inside the boundary branch. Today it runs
unconditionally, before the `handoff`/`precompact` case; under `autoname` it
must not run at all. This is the load-bearing half of the change: `autoname`'s
description promises no memory write, and a memory directive is an instruction
to make one.

The sentinel's state stays `armed` without a special case. `held` requires a
typed transition **and** a memory directive; kind `rename` produces neither.

`write-drive.sh` is deleted with its `PostToolUse(Write|Edit)` entry, leaving
`write-stage.sh` alone on that event. `write-guard.sh` takes `autodrive` as a
second (basename, rel) pair — `handoff_match_target` is already variadic and
sets `MATCHED_NAME` — and denies the write outright, cross-project or not. The
arm-only rule dies with the file it lived in: with no agent writer, the
constraint has no subject, and the checkpoint validates its own output by
read-back.

`bash-post.sh` is untouched. An `autoname` call writes a zero-line manifest,
whose consumption is already covered.

## Consequences for autoname's contract

It gains a Bash call and loses a Write. The "make no tool calls to decide the
title" rule is unaffected — that governs deriving the title, not writing the
result — and stays as written.

It gains the root-pointer refusal every other checkpoint caller has: no
pointer, no rename. That is a new failure mode, taken deliberately in exchange
for the cwd-relative write it replaces, which fails silently and in the harder
direction.

## Rejected alternatives

- **Have `autoname` call the checkpoint as `skill: "handoff"` with
  `clear: false` and nulls elsewhere.** Legal today, and it composes the right
  sentinel. Rejected: it also composes the memory directive and the todo
  boundary, so `autoname` would instruct a memory write. Suppressing them needs
  a discriminator, which is the third `skill` value arrived at by a longer road.
- **Keep `write-drive.sh` as defence in depth.** With the write denied at
  `PreToolUse`, its match can no longer fire; a hook that cannot run is not
  depth, it is a second parser position to keep in step.
- **Leave `autoname` alone and dedupe the template by generating it.** The
  template is prose in a skill body; nothing generates into one, and the
  duplication is the artifact, not the text.

## Tests

`tests/checkpoint.bats`:

- `skill: "autoname"` accepted; the payload's exact sentinel content, read back
  through `handoff_drive_read` as kind `rename` in state `armed`.
- Each forbidden field under `autoname` — `task`, `todo`, `clear`, `compact`,
  `continue`, `commit` — asserting a non-zero exit naming the field.
- `rename` missing under `autoname`: non-zero, names the field.
- The load-bearing negative, mutation-checked rather than observed passing:
  an `autoname` call against a **dirty memory submodule** emits no directive at
  all. Restore the unconditional `checkpoint_memory_directive` and this row must
  go red while the `handoff` and `precompact` directive rows stay green.
- The manifest is written and empty.

`tests/hook-test.bats`:

- `write-guard.sh` denies a Write and an Edit to `.claude/autodrive`, and the
  cross-project deny names `autodrive` via `MATCHED_NAME`.
- `write-guard.sh` still denies `handoff-task.md`, and still exits 0 on an
  unrelated path — the second pair must not disturb the first.
- The `write-drive.sh` rows are deleted, not skipped.

## Docs

`docs/changelog/2026-08-09-one-writer-for-the-sentinel.md` plus its index line,
and the `CLAUDE.md` entries for `write-drive.sh` (removed), `write-guard.sh`,
`skills/autoname/SKILL.md`, `checkpoint.sh` and `hooks.json` (nine hooks, not
ten) rewritten in the same pass.
