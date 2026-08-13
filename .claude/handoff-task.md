## Current task

Live-testing the driven `/compact` transition, as the dogfood for a fix to the
walker's pane predicates. The fix, its tests, the changelog entry and the
memory update are committed; this compaction is the test.

**Verify on the far side:** both walker lines — `/compact`, then the
continuation prompt — landed hands-off, with no `.claude/autodrive.failed`
report at the first `UserPromptSubmit`. A failure report naming a line is a
result, not a setback: record it, since the walker's Enter-and-confirm path
(`_submit_until`) had never once run in production before this change. Every
earlier failure aborted before the first Enter, so that path is unproven, not
proven-good.

**Background.** `is_typing` matched `❯[ \t]+\S` while the TUI pads the
composer with U+00A0, so every driven line ever typed aborted with "did not
land in the composer" while sitting in the composer. The window-activity
correlation was observability, not mechanism: with the pane on screen a human
presses Enter and the transition completes.

The predicate is now split by the question asked — `line_landed` for "did my
line land", cursor-keyed `composer_has_user_text` for "is the user
mid-compose" (an idle composer is never empty; the TUI paints a faint
placeholder). Both poll rather than sampling once. `is_busy` learned the
`(8m 30s ·` timer form. `just tui-conformance` checks the frozen fixtures
against a live TUI; it is deselected from `just precommit` and needs an
unsandboxed shell.

Full reasoning: `docs/changelog/2026-08-13-predicates-match-the-real-pane.md`.
