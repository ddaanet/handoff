# 2026-08-13 — Composer predicates match the real pane

The walker had not delivered a line in some time. Every driven transition
failed the same way, and the failure report said so:

> `/rename …` did not land in the composer — a dead pane or copy mode may have
> swallowed it.

It had landed. `is_typing` matched `❯[ \t]+\S`, and the TUI pads the composer
with U+00A0, not a space. One character, and the predicate was False for every
line the walker ever typed.

## Why it read as a tmux problem

It was reported as *"unreliable when the window is not the active tmux
window"*, and that framing is worth recording because it was a reasonable
inference from a real correlation. The correlation is in the observer, not the
mechanism: the walker aborts before pressing Enter and leaves the line sitting
in the composer, so with the window on screen you see it and press Enter
yourself, and the transition completes. In another window nobody does, and it
strands. The failure rate is 100% either way.

Two probes killed the tmux hypotheses. A pane in a non-active window repaints
and is captured faithfully — a marker typed into one showed up in the capture
at 0.3s. `focus-events on` (set in the user's config, commented "Focus
handling for claude") changes nothing about that. The first probe appeared to
show the opposite, with the active window slower, but its first cell ran
during TUI boot; ordering was the confound, and re-running with a settle
inverted it back.

## Why the suite was green

Every fixture was hand-written with an ASCII space —
`TYPING_TEXT = "…❯ hello there…"`, and no U+00A0 anywhere under `tests/`. They
encoded what the author assumed the pane looked like, and nothing ever
compared that against a pane. The predicate suite tested the predicate against
its own premise.

That is the durable defect. The character was a symptom.

## What was weighed

**Retune the character class.** `\s` matches U+00A0 and would have shipped in
a line. Rejected as the whole fix: it repairs today's instance and leaves both
mechanisms — a hand-written fixture, and a predicate carrying an opinion about
padding it has no reason to hold.

**Freeze captures as fixtures.** Necessary but not sufficient on its own, for
the same reason: a capture frozen today is a hand-written fixture tomorrow.

**A live helper instead of fixtures.** Rejected for the unit suite. A test in
the gate must fail for one reason, and a helper driving a real TUI reds for
TUI drift, boot timeouts, missing auth, or no tmux. It also cannot run in the
agent's sandbox, which blocks socket creation. A suite that reds for reasons
unrelated to the code trains its reader to ignore red.

**Both, split by job.** Taken. Frozen captures carry the assertions; a
separate non-gating probe (`just tui-conformance`) asserts that those frozen
strings still match a live TUI. It tests the fixtures, not the predicates, so
when the TUI drifts it says "re-capture" rather than "your code is broken". It
submits nothing, so it costs no tokens.

## What the live probe found immediately

Writing it was not ceremony. On its first run it failed on two things the
frozen suite could not have known:

**The composer is never empty.** An idle composer paints a rotating
suggestion — `❯ Try "how does hook-test.bats work?"` — in faint SGR. So "is
the composer non-empty" was answering a different question than either caller
was asking, and widening the class to `\s` would have *armed* the pre-send
bail against every placeholder, aborting lines before they were typed. The
one-line fix, shipped alone, would have been worse than the bug.

**The rejection text lands late.** "No commands match" is painted somewhere
between 0.5s and 2s after the send — measured at ~1s and ~2s on consecutive
runs of the same probe. The recognition check read the pane once at
`VERIFY_DELAY` and therefore never saw it, passing unknown commands straight
through to Enter.

And a third, found when the gap assertion flaked: **the composer does not
always repaint within `VERIFY_DELAY` either.** One run in four showed the
placeholder still there 0.5s after the send. Read once, a late repaint is
indistinguishable from a swallowed keystroke — which is very likely the
residual "unreliable" that would have remained after fixing only the
character.

## The shape it settled into

One predicate was being asked two questions that want different evidence, and
splitting them dissolved most of the problem.

- **"Did my line land?"** — `line_landed(text, line)` asks whether the
  composer holds *the line just typed*. It needs no opinion about padding, so
  the whitespace class stops being load-bearing, and the placeholder is
  irrelevant to it. Whitespace is squashed on both sides so a row-wrap that
  splits a word mid-way still matches, and the region is bounded to the last
  glyph row so prose echoed in the scrollback above cannot satisfy it.
- **"Is the user mid-compose?"** — `composer_has_user_text(text, cursor_x,
  cursor_y)` keys on the **cursor**, which is the only thing that separates the
  TUI's own suggestion from something a person typed: the placeholder paints
  characters but never moves the cursor off the start column. The start column
  is derived from the captured line rather than pinned, so a layout change
  cannot invert it silently.

Rejected for that second job: detecting the faint SGR. It is a real
discriminator — the placeholder is `\x1b[2m` and typed text is coloured — but
it couples the predicate to the TUI's theme and forces `snap` to stop
stripping ANSI for every other caller.

Both remaining pane reads now poll rather than read once, with the window
sized from the slower observation rather than the typical one.

`is_busy` had the same class of defect, found while checking the neighbours:
`\([0-9]+s ·` does not match `(8m 30s ·`, because past a minute the seconds
stop abutting the paren. The re-gate FR-H depends on was therefore inert for
every turn over 60s — exactly the turns that matter, since confirming a line
can take `CONSUME_TIMEOUT` (300s).

## Residuals

- A user who types and then sends the cursor home reads as an idle composer,
  and the walker's send will concatenate onto their text. No signal on this
  pane distinguishes the two.
- A machine slower than the recognition window still Enters an unknown
  command. The conformance probe asserts against that exact tunable, so drift
  fails there rather than inside a transition.
- `is_busy`'s two timer forms stay fixture-only. Reaching a spinner needs a
  submitted turn, and the probe deliberately submits nothing.
