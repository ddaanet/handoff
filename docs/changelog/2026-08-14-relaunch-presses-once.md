# 2026-08-14 — The relaunch presses Enter once

Three driven restarts in a row left the relaunch line sitting at the shell
prompt, typed and never submitted:

```
 dev  .venv  ~/c/handoff  main ↑5 ✚7> claude --settings \{\"autoMemoryDirectory\":…\} --plugin-dir … -c --resume e2dc9301…
```

The walker had pressed Enter — every path through `submit_consumed` presses
before it checks anything, and the walker's exit profile (sentinel consumed,
no failure recorded) says it got there. The keystroke did not take.

## Not reproducible

Six probes, each against a real tmux pane on a private socket:

- `send-keys -l` then `send-keys Enter` into an idle fish — executes.
- The same into a *busy* fish (a running `sleep`), which is what a slow prompt
  looks like: the tty buffers text and Enter, and fish executes the line when
  it regains control. This killed the mechanism that fit best on paper — a
  shell flushing its input queue as it re-initializes the terminal, discarding
  a keystroke that arrived between the process dying and the prompt drawing.
- `_drive_shell_line` standalone against a pane whose foreground flips from a
  fake `claude` to the shell — typed, Entered, ran.
- The full two-line sequence against a **real** Claude Code TUI: `/exit`
  confirmed through `SessionEnd`'s marker, the gate opening, the line typed
  and Entered, and the pane coming back with Claude Code's resume picker.

## The first answer, and why it did not survive contact

Keep pressing. `_submit_until` stops after three and waits in silence, on the
reasoning that a registered Enter can take far longer than `VERIFY_DELAY` to
reach its signal and a composer that already took one would submit the turn
twice — the second half being a TUI property that a shell prompt does not
share. So the shell path resent for the whole poll.

The next restart worked. So did the one after it, with the resend switched
back off — by then [argv replay was
gone](2026-08-14-the-relaunch-stops-replaying-argv.md) and the line had shrunk
from ~200 characters of `%q`-quoted flags to `claude --resume <sid>`. The
losses stopped when the long line did, which is the closest thing to a cause
this ever produced, and it is still only a correlation across three runs.

What the resend did leave behind was visible: an extra Enter at the prompt on
every restart. It could not not be — the signal it retried against is the
sentinel going, which the resumed session's `SessionStart` does, and a whole
Claude Code boot sits in between. Every check at +0.5s and +1.0s was
guaranteed to fail and press again, into a session already starting. At a
shell prompt a stray Enter is an empty line; in a booting Claude Code it
answers whatever dialog is on screen — a folder-trust prompt, a permission
ask. The remedy had a worse failure mode than the fault.

## Delivery and confirmation are two questions

For a TUI line they collapse into one: the only evidence the keystroke
arrived is the thing it caused, which is why that path has to guess and then
stop guessing. A shell line has a second signal, immediate and local — the
pane's foreground command leaving the shell, which means the line ran.

So `submit_launched` presses Enter only while the shell is still in front,
which is precisely the evidence that the keystroke has not been taken, and
returns the moment anything else is. `wait_for_consumed` then waits for the
sentinel without touching the pane at all. The happy path presses once; a line
that genuinely does not run is pressed again and then failed loudly, naming
the shell that kept the pane.

The `resend` flag is gone, and `_submit_until` is back to what it was for the
three TUI primitives. The `/compact` row asserting exactly three presses stays
beside the new one asserting exactly one — the two rules are opposite and each
is now pinned.
