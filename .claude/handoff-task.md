## Current task

`/orchestrate` on `plans/2026-09-04-checkpoint-null-no-task-file/runbook.md` is executed end to end — Phases 0-4 plus Item 1.2, each with its checkpoint review, and the closing `edify:tdd-auditor` pass. What remains is the deliverable review, which the runbook wants in a fresh opus session, carrying the five product observations the audit declined to develop.

The change replaces `checkpoint.py`'s `task`/`todo` payload with a tagged union: the file's content as a string, or an object naming an action — `clear` on both, `keep` and `edit` on `todo` alone. Both keys are required by key presence, so `null` and an absent key are each a named error, and `file_path` is gone, the path being composed from `HANDOFF_ROOT`.

A `/clear` does not reload plugin skill bodies, so a wrap-up call from the session this opens may still compose against the pre-Phase-3 snapshot, which shows the retired `file_path` + `content` shape. If `handoff-checkpoint` exits 2 naming `task`, that is why: send the union directly, or `/reload-plugins` first.
