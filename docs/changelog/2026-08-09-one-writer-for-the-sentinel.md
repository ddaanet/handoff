# 2026-08-09 — One writer for the sentinel

Third pass of the transition work. The state machine
([2026-08-03](2026-08-03-one-transition-one-file.md)) and the collapse of the
driven skills into payload fields
([2026-08-05](2026-08-05-transitions-become-modes.md)) both left `autoname`
alone, and the second recorded this change as a rejected alternative because it
alters that skill's contract. This is that change, on its own.

## The defect

`.claude/autodrive` had two producers. `checkpoint.sh` composes it from the
payload's transition fields and reads its own output back through
`handoff_drive_read`, so composer and parser cannot drift. `autoname` wrote it
with the `Write` tool from a three-line template in its skill body, and
`write-drive.sh` validated that write at `PostToolUse` — a second parser
position, a second set of failure messages, and a rule (*the agent writes only
`armed`*) that existed solely because an agent held the pen.

The template was the drift surface. The checkpoint already composed exactly the
sentinel `autoname` wrote — kind `rename`, one `/rename` line — under
`skill: "handoff"` with `clear: false`, and said so in a comment. Two producers
of one artifact, one of them prose in a file nothing validates against the
parser.

`autoname` also addressed the file as `./.claude/autodrive`, relative to the
session cwd. Every other writer resolves the root from the session pointer
precisely because cwd drifts
([2026-07-31](2026-07-31-session-root-drift.md)); `autoname` was the one path
still writing wherever the shell happened to be while every reader stayed at
the root.

## The change

`skill` takes a third value, `autoname`, whose payload is two fields:

```json
{"skill": "autoname", "rename": "<title>"}
```

`task`, `todo`, `clear`, `compact`, `continue` and `commit` are each a schema
error under it, exactly as `rename` is under `precompact`. The rule the schema
already followed is that a field is required where it carries a judgment and
forbidden where it would be a silent no-op; `autoname` makes no
commit-awareness decision, no transition decision and no continuation decision,
so it carries no field for one.

`checkpoint_memory_directive` moved inside the boundary branch. It used to run
unconditionally, ahead of the `handoff`/`precompact` case; under `autoname` it
must not run at all. This is the load-bearing half: `autoname`'s description
promises no memory write, and a memory directive is an instruction to make one.

The sentinel's state stays `armed` with no special case. `held` requires a typed
transition **and** a memory directive, and kind `rename` produces neither.

`write-drive.sh` is deleted with its `PostToolUse(Write|Edit)` entry, leaving
`write-stage.sh` alone on that event. `write-guard.sh` takes `autodrive` as a
second (basename, rel) pair — `handoff_match_target` was already variadic and
already set `MATCHED_NAME` for exactly this — and denies the write outright,
cross-project or not. The arm-only rule dies with the file it lived in: with no
agent writer, the constraint has no subject, and the checkpoint validates its
own output by read-back.

`bash-post.sh` is untouched. An `autoname` call writes a zero-line manifest,
whose consumption was already covered.

## Consequences for autoname's contract

It gains a Bash call and loses a Write. The *make no tool calls to decide the
title* rule is unaffected — that governs deriving the title, not writing the
result — and stays as written.

It gains the root-pointer refusal every other checkpoint caller has: no
pointer, no rename. That is a new failure mode, taken deliberately in exchange
for the cwd-relative write it replaces, which fails silently and in the harder
direction.

## Rejected alternatives

- **Have `autoname` call the checkpoint as `skill: "handoff"` with
  `clear: false` and nulls elsewhere.** Legal before this change, and it
  composes the right sentinel. Rejected: it also composes the memory directive
  and the todo boundary, so `autoname` would instruct a memory write.
  Suppressing them needs a discriminator, which is the third `skill` value
  arrived at by a longer road.
- **Keep `write-drive.sh` as defence in depth.** With the write denied at
  `PreToolUse`, its match can no longer fire; a hook that cannot run is not
  depth, it is a second parser position to keep in step.
- **Leave `autoname` alone and dedupe the template by generating it.** The
  template is prose in a skill body; nothing generates into one, and the
  duplication is the artifact, not the text.
