# Read-time assembly: pointer + bounded scrape (2026-06-05)

> **Superseded 2026-07-17** (see [Task frame drops the transcript and file
> list](2026-07-17-task-frame-drops-transcript.md)): the scrape is gone, and
> with it the pointer chain this section built — `.claude/handoff-session`,
> `extract.py`, and `handoff-error.log`. `load-handoff.sh` now assembles the
> frame from the task file alone.

**Supersedes, below:** the [Activation: PostToolUse
extraction](2026-05-19-original-activation-and-loading.md) mechanism (the
`handoff.md` generation half — the `handoff-task.md` template authoring is
kept), the [Output schema](2026-05-19-original-activation-and-loading.md)
(`handoff.md`), the `handoff.md` branches of the read/write guards, and the
"reads `handoff.md`" mechanics of
[Loading](2026-05-19-original-activation-and-loading.md). The
`handoff-task.md` authoring, the wipe-at-activation, the cross-project
guard, and the SessionStart `additionalContext` injection are unchanged.
Earlier strata that already conflicted with the chosen design (the
`handoff-pending.json` [Marker file
schema](2026-05-19-original-activation-and-loading.md)) were never
implemented and remain history.

## The defect

`handoff.md` is a generated file derived from `handoff-task.md` and
`git add -f`'d next to it — a non-versioned twin shadowing a versionable
source. It also inlines the verbatim last-N user prompts, so committing it
would dump raw transcript into history. And `PostToolUse` extraction freezes
the scrape at handoff time, which is both an extra hook event and the wrong
moment — the tail of the transcript at that instant is the "save handoff"
request itself.

## The change

Eliminate `handoff.md`. The assembled frame becomes ephemeral — built in
memory at read time, never written.

- **Pointer, not artifact.** At handoff activation, persist the session's
  `transcript_path` to `.claude/handoff-session` (machine-local). Every hook
  payload already carries `transcript_path` (`write-extract.sh` reads it
  today).
- **Read-time assembly.** `load-handoff.sh` (SessionStart): if
  `handoff-task.md` exists, read the pointer, scrape that JSONL, assemble
  `handoff-task.md` + extracted sections, emit via `additionalContext`.
  Pointer's JSONL missing → inject the task file alone. No task file →
  silent no-op.
- **Bounded scrape.** The scrape cuts at the last handoff activation in the
  pointed JSONL, reusing the `handoff_activated()` signal: a `Skill` tool_use
  with `skill ∈ {handoff, handoff:handoff}` — the dependable marker; the
  `/handoff:handoff` slash shape is unverified (may be a `<command-name>`
  wrapper), per the guard section. Last-N user prompts are taken *before*
  the cut.

## Why bounded

Read-time scraping otherwise runs to `/clear`, capturing prompts typed
*after* the handoff. The effect is asymmetric: if those continue the task
they help only marginally (the task frame is already in `handoff-task.md`);
if they digress, the next session glues the task frame to unrelated recent
prompts and anaphora ("do it that way") resolves to the wrong thing —
silently. The cut excludes both the digression and the "save handoff"
request. The frozen-at-handoff semantics the old `handoff.md` got right are
preserved; only the generated file is dropped.

## Versioning `handoff-task.md`

Removing the scrape from the file leaves `handoff-task.md` as pure judgment
prose — clean to track. The handoff flow already writes durable learnings to
auto-memory in the same turn; under **gitlore** that write becomes a versioned
memory commit. So `handoff-task.md` (task frame, main repo) and the gitlore
memory commit (durable context) form a paired, in-history record — gitlore
supplies the surrounding context the task frame omits, which is what makes
versioning it worthwhile rather than noise.

- **Track** `handoff-task.md`. Keep a slim `PostToolUse(Write|Edit)` hook
  filtered to it doing only `git add -f handoff-task.md` (the staging
  survives from `write-extract.sh`; the `extract.py` regeneration does not).
- **Gitignore** the pointer (`handoff-session`) and `handoff-error.log` —
  machine-local.

## Consequences (accepted)

- **No self-contained committable artifact.** Not a loss — the durable
  context lives in gitlore's versioned memory, not in a baked scrape.
- **Non-atomic pairing.** gitlore commits memory at handoff time;
  `handoff-task.md` enters history at the user's next main-repo commit. The
  two halves drift; the user's commit is the sync point.
- **Wipe-churn.** Tracked + wiped-at-activation = delete/rewrite each
  handoff, deletion on finalize. A real trail of task transitions, churny in
  the top-level log, isolated via `git log .claude/handoff-task.md`. The wipe
  *stages* the deletion (`git add -f` on the now-absent path, in
  `_wipe-emit.sh`), mirroring the write-side `git add -f` in `write-stage.sh`
  — otherwise a finalized/transitioned task would linger as an unstaged
  removal and never ride the user's next commit. Suppressed no-op when the
  file was never tracked or the root isn't a git repo.
