# One channel, one writer (2026-07-27)

The wrap-up was five mechanisms sharing one act: an activation hook wiped the
prior files, the agent issued three Write calls, a `PreToolUse` guard vetted
each against a transcript-scraped activation predicate, a `PostToolUse` hook
staged each, and a separate Bash call ran the probe. Each piece was locally
sound. Together they encoded an assumption that does not hold — that a session
hands off once.

The wipe is where it shows. It fires on activation, and activation is not
the event it wants. Multiple compactions in a session are normal; repeated
`/handoff` invocations, slash or agent-driven, happen too. Every one
destroys `handoff-todo.md` before the agent has re-authored it. That file is
the half of the frame a `/clear` discards outright, and after a compaction
the context it would be re-authored from is a paraphrase. [precompact resets
the task file too](2026-07-21-precompact-resets-the-task-file.md)
(2026-07-21) argued the reset was a harness guarantee where "the skill
writes the whole file" is only an agent-compliance guarantee. That reasoning
holds for the task file, which is authored fresh from the conversation every
time. It never held for the todo remainder, which is a ledger — and the two
were given one protocol because they shared one activation hook.

So the todo file stops being wiped and starts being edited. It is a scratch
list by design: the agent strikes finished items and adds new ones all session,
and the wrap-up folds in the final remainder rather than regenerating the
document from a paraphrase.

Removing the wipe exposes what it was silently paying for. The Write tool
refuses to overwrite a file it has not Read in the current conversation, and an
absent file is what let the skill Write both as fresh creates. The fix is not
to restore a deletion but to stop routing the write through the Write tool at
all. The skill assembles the whole wrap-up as JSON — the task frame, the todo
Write or Edit, the session title, the commit-awareness answer — and pipes it to
`handoff-checkpoint` on stdin. One call replaces a wipe, three writes and a
probe.

The payload uses the harness's own tool-call shape (`file_path` + `content`, or
`file_path` + `old_string`/`new_string`) rather than a bespoke one. It is
redundant — the checkpoint owns the paths — but it is the shape the agent emits
most reliably, and validating `file_path` strictly against
`$root/.claude/<name>` is where the cross-project guard lives for this path.
The cost is a new failure mode: multi-line markdown inside a JSON string is
`\n`-escaped, and a botched escape is a way the wrap-up can fail that a Write
call never had. That is what the schema validation is for, and why a violation
must name the field rather than merely exit non-zero — a silent drop lands at
exactly the moment nothing else carries the frame.

"Probe" no longer describes it. The two probes were read-only detectors; this
writes. One `handoff-checkpoint` replaces both, with the transition as a
payload field — the schema already forces a discriminator in, so two binaries
differing only by it were the duplication the channel makes redundant.

**What the checkpoint may not do.** It runs in the agent's sandboxed Bash,
where a `git add` can stage successfully yet fail to remove `.git/index.lock`,
and the failure surfaces on the *next* command as `Another git process seems to
be running`. The next command here is the routine one: the wrap-up is
`/handoff` then `/commit`. tmux is likewise unreachable, so writing
`.claude/autorename` from the checkpoint would leave the rename watcher
unspawned and the promise of a rename unkept. Both jobs stay in hook context,
reached the way this plugin already reaches them — a file the checkpoint leaves
behind and a hook consumes. `PostToolUse(Bash)` stages the manifest's paths and
spawns the watcher.

**Content, not activation, decides absence.** A file whose body is empty is
removed and the removal staged. `file present ⟹ content pending` becomes an
invariant two writers enforce, instead of an instruction the agent has to
remember. That was the wipe's real job, and it survives the wipe.

Deleting the activation hooks removes the last consumer of `handoff_activated`,
and with it the transcript scraping and its JSONL fixtures. The predicate was
always a proxy — "has a skill run?" standing in for "is this write legitimate?"
— and the channel answers the real question directly. `write-guard.sh` keeps
one file and one rule: `handoff-task.md` is written by the checkpoint or not at
all. `read-guard.sh` goes entirely; a scratch list the agent edits must be
readable, and gating reads of the task file alone protects nothing.
`write-stage.sh` narrows to the todo file, which is the one path the checkpoint
never sees.
