# 2026-07-01 — `release` dropped its confirmation prompt and `--yes` (v0.3.0)

Removed the interactive confirmation prompt and the `--yes` argument from the
`release` recipe. `just release [bump]` is now non-interactive: the recipe runs
behind Claude Code's permission layer (or a human's own `just` invocation),
which already gates the command, so the inner `read -rp` prompt re-asked the
same question and `--yes` existed only to silence it in the common case where
an outer gate was present — that is, almost always.

Pre-flight guards are unchanged; only the keystroke was removed. The same
applies to this repo's own self-release recipe. See "No interactive
confirmation in `release`" in [design.md](../design.md).
