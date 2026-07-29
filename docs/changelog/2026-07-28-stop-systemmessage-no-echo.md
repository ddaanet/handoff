# Stop's systemMessage stops echoing the compact directive (2026-07-28)

`stop-compact.sh`'s `systemMessage` used to interpolate the full `$COMPACT_L1`
(`/compact <directive text>`) into the arming confirmation: `will run
"/compact <directive>" once the prompt is idle …`. The directive can be long
(a paragraph of continuation context), and the watcher types that exact line
into the pane moments later — so the user saw it twice, once as a diagnostic
aside and once as the actual command executing. The fix drops the
interpolation and states only that `/compact` will run, keeping the pane
number (the one piece of that message a diagnostic reader can't get any other
way). `$COMPACT_L1` itself is unchanged and still carries the full directive
to the watcher and to the not-in-tmux paste-it-yourself fallback, where no
second rendering exists to duplicate it.
