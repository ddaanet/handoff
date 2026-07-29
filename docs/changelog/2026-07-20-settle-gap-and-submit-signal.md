# The settle gap and the submit signal (2026-07-20)

The first live run submitted line 1 and silently failed to submit line 2; the
operator pressed Enter without it being obvious that the watcher had not.

Two defects, stacked. An Enter sent immediately after a long literal
`send-keys -l` lands inside the TUI's paste window and is absorbed as a line
break. `compact-when-idle.sh` never hit this because its recognition readback
sits between the text and the Enter — the delay was load-bearing for
*submission*, not just verification, which was invisible until line 2 dropped
the readback on the reasoning that prose needs no recognition check. The gap is
now explicit in both watchers, with a comment saying it is not redundant.

The second defect is why it went unreported. Verification asked `is_typing`
whether the composer had drained, but `is_typing` inspects only the last `❯`
line, and an absorbed Enter leaves a multi-line composer whose last `❯` line is
empty. The watcher read that as drained, exited 0, and the run looked clean.
Verification now keys on `is_busy` — the turn actually started — which is
unambiguous on a multi-line composer. "Composer looks empty" was never evidence
of a submit; "the session went busy" is.
