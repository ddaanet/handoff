## Current task

Testing the read-time assembly feature: this frame was assembled at SessionStart from the session pointer, not from a pre-generated handoff.md file.

## Open decisions

- Confirm the assembled frame appears correctly in the next session's context (no handoff.md on disk, content injected via additionalContext).
