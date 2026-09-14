# A heading is not a leading `#` (2026-09-14)

`is_empty_body` is FR6's whole definition of empty — the one rule
`checkpoint.py` and `write-stage.sh` share so the two writers cannot disagree
about when a file should be removed. It read:

```python
if line == "" or line.startswith("#"):
    continue
```

Two spellings were wrong, in opposite directions.

**A whitespace-only body was content.** `line == ""` is not "blank", so a line
of spaces was neither blank nor a heading and the body counted as written.
`"task": "   "` exited 0 with a `W` manifest line and a three-byte file on
disk — which then passed `handoff_frame`'s `-s` gate, since that gate measures
bytes, and was injected into the next session as a task frame carrying
nothing.

**A `#` at the start of a line was a heading.** `startswith("#")` skips
`#!/bin/sh`, `#tag` and a run of seven `#` as readily as `## Remaining`, so a
body made of those was judged empty and the file was *removed*. The loss is
the asymmetry that matters: the first defect injects a frame that says
nothing, the second deletes one that said something.

Both were filed against the payload-union job — the first as m4, the second by
the fix-status audit, which attached it to m4 precisely so that the eventual
pass would be scoped to both rather than closing one and leaving its twin.

## The rule now

A line is skipped iff, with trailing whitespace removed, it is empty or an ATX
heading: up to three leading spaces, one to six `#`, then the line's end or
whitespace before the text.

That is markdown's own rule, and the leading-space bound is the part worth
stating. The obvious spelling is to strip each line and test the result, which
closes both routes as filed — and re-opens the second one indent along. Four
leading spaces open a code block, so

```
## Remaining

    # run the migration first
```

has a `# comment` as its only content, and a rule that strips first reads it
as a heading and removes the file. Testing the line with only its *trailing*
whitespace gone keeps the two apart: three spaces indent a heading, a fourth
makes the line content, exactly as a shebang is content.

The bound is why the pattern is a regex rather than a widened `startswith`.
Seven `#` is not a heading either, for the same reason `#tag` is not — what
follows the run has to be whitespace or nothing.

## Evidence

Four rows across the two suites, because the predicate has a caller on each
side of the bash/python split: two in `tests/test_checkpoint.py` for the
whitespace body (task half and todo half — the audit found the todo side of a
sibling removal branch dead to the suite once before), one for the shebang
body, and one in `tests/hook-test.bats` driving `write-stage.sh`, the bash
caller, over an agent's own direct edit. A parametrized pair pins the indent
boundary from both sides.

Each half of the predicate is mutation-checked separately against the shipped
file: restoring `line == ""` reds the two whitespace rows and nothing else;
restoring `startswith("#")` reds the shebang row and the three-space row;
stripping instead of rstripping reds the four-space row alone. A heading-only
body was already covered and did not need a new row.

## Not changed

`handoff_frame`'s `-s` test in `_lib.sh` stays a byte-length check. With the
predicate right, no writer produces a whitespace-only file, and re-deriving
emptiness in bash would put a second implementation of this rule beside the
shared helper that exists to prevent exactly that drift. Two routes survive
that gate, both outside the two writers: a process writing the file through
Bash rather than `Write`/`Edit` misses `write-guard.sh`, which is registered
on those two tools only; and a file already on disk from before this change is
not swept retroactively by anything.
