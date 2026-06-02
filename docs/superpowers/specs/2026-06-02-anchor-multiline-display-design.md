# Anchor multi-line display

Date: 2026-06-02

## Problem

`anchor_for` in `extract.py` has two sins:

1. **Line truncation with no indicator.** When the assistant turn is
   multi-line, only the first line is shown — the reader cannot tell
   more existed.
2. **No char-limit indicator.** The 120-char cut (`[:ANCHOR_TEXT_LIMIT]`)
   on the first line produces no trailing `…`.

User prompts are shown verbatim (all lines, no truncation) and are not
in scope for this change.

## Decision

Fix both sins in the **text-type branch of `anchor_for`** only:

- If the assistant text is **≤ 5 lines**: show all lines.
- If the assistant text is **≥ 6 lines**: show first 2 lines, then
  `[…]`, then last 2 lines.
- Remove the `[:ANCHOR_TEXT_LIMIT]` char truncation from this branch.
  Lines are shown in full.

The `ANCHOR_TEXT_LIMIT` constant is kept — it still applies to command
truncation in the `tool_use` path.

Tool-use anchors (`[Edit] path`, `[Bash] command`) are single-line
strings and are unaffected.

## Output format

The anchor is now potentially multi-line. `emit` changes from:

```
**after {anchor}**
```

to:

```
**after** {first anchor line}
{subsequent anchor lines, if any}
```

`**after**` becomes a standalone bold label; the anchor text is plain
inline text below it. This keeps the anchor visually distinct from the
`>` blockquoted user prompt that follows.

## Constants

Three new constants at the top of `extract.py` (alongside existing ones):

```python
ANCHOR_LINE_LIMIT = 5   # show all lines if count <= this
ANCHOR_HEAD_LINES = 2   # lines to show before [...]
ANCHOR_TAIL_LINES = 2   # lines to show after [...]
```

## Implementation

`anchor_for`, text-type branch:

```python
# before
return text.splitlines()[0][:ANCHOR_TEXT_LIMIT]

# after
text_lines = text.splitlines()
if len(text_lines) > ANCHOR_LINE_LIMIT:
    text_lines = text_lines[:ANCHOR_HEAD_LINES] + ["[…]"] + text_lines[-ANCHOR_TAIL_LINES:]
return "\n".join(text_lines)
```

`emit`, anchor rendering:

```python
# before
lines.append(f"**after {anchor}**")

# after
anchor_lines = anchor.splitlines()
lines.append(f"**after** {anchor_lines[0]}")
for al in anchor_lines[1:]:
    lines.append(al)
```

## Testing

One new fixture scenario in `tests/extract-test.sh`:

- Assistant turn with ≥ 6 lines of text.
- Assert: first two lines present, `[…]` present, last two lines
  present, intermediate lines absent.

Existing fixtures (short assistant turns) pass unchanged — the
`splitlines()[0]` path is replaced but the single-line result is
identical for one-line assistant text.
