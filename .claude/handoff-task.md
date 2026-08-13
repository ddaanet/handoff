## Current task

Executing plans/2026-08-13-restart-drive-repair.md. Three tasks repairing a
driven restart, whose two defects share one root: nothing in the plugin ever
identifies the claude process. Task 1 gives handoff_resume_command a bounded
parent-chain walk, since PPID inside a hook is the /bin/sh -c wrapper Claude
Code spawns and its argv is the hook command line, not a launch line. Task 2
replaces the fixed settle before the relaunch with a gate on the pane's
foreground command, because Claude Code stops consuming input well before it
releases the terminal. Task 3 is the design record for both.

Tasks 1 and 2 are independent and may land in either order; Task 3 needs both.
The plan carries the evidence, the code, and two mutation checks per task that
must actually be run — a green row that survives its mutation is not evidence.

Task 1 also replaces the HANDOFF_TEST_CMDLINE_PATH seam with a fake process
tree. That is not cleanup: the old seam substituted for the exact expression
that was wrong, which is why the defect stayed green.
