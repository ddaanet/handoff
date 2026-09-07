# Item 1.1 slice 2 — test review

Verdict: **accepted with fixes applied.** The report's three-mutation matrix
reproduces exactly, independently, on my own runs — no disagreement on any
cell. `git diff scripts/checkpoint.py` was empty when this review began and is
empty now; no mutation was left in.

Two findings against the tests, both fixed, both re-mutated afterwards to
confirm the fix did not make a row unfalsifiable:

- **Major** — the slice's own claim, "at the two boundaries", was pinned at
  *one* boundary. Narrowing `main`'s gate to `if skill == "handoff":` left the
  entire repository green (159 bats + 201 pytest). Fixed by adding a `skill`
  dimension to the table.
- **Minor** — the `null` row and the `absent` row of a field asserted the same
  thing (`field in stderr`), so an exchange of the two diagnostics passed
  undetected. Fixed by pinning each shape's own reason.

Test count moves **111 → 115**, against the dispatch's stated expectation of
111. That is the major fix; the rationale is below and the decision to keep or
revert it is the orchestrator's.

## Mechanical first check — the matrix, reproduced

Method: `scripts/checkpoint.py` mutated **in place** by a scripted patcher
(`assert s.count(old) == 1` before every replacement, so a mutation that
failed to apply is an error rather than a silent green), run, then restored
with `git checkout --`, with `shasum` and `git diff | wc -l` confirming the
restore after each cycle. Tests never relocated.

One caveat about my own first pass, recorded because it is the failure mode
this method has: my first restore silently no-op'd (`$TMPDIR` was empty in
that shell, so `cp "$TMPDIR/…"` failed), and mutation B ran stacked on top of
mutation A — which reddened all four rows and would have read as "A and B are
not disjoint", the exact critical finding I was told to watch for. Caught by
the `cp: cannot stat` line in the output, redone from a `git checkout`
baseline. Every cell below is from a single-mutation run off a verified-clean
tree.

### Against the table as submitted (4 rows)

| Mutation | task_null | task_absent | todo_null | todo_absent |
|---|---|---|---|---|
| **A** — `null` accepted as an empty write | **RED** | green | **RED** | green |
| **B** — absent key falls back to a default | green | **RED** | green | **RED** |
| **C** — `main` writes the target before validating | **RED** | **RED** | **RED** | **RED** |

**Agrees with the report cell for cell.** A and B red disjoint sets, so the
key-presence rule and the value-shape rule are separately exercised — the
load-bearing property. C reds all four *on the file-not-created assertion
specifically*, not on the exit code: every failure is at that assertion's line
and names the row's own file (`handoff-task.md` for the task rows,
`handoff-todo.md` for the todo rows). That half is evidence, not decoration.

### Field naming — no exchanged-predicate pass

Probed the four messages by running `checkpoint.py` directly:

| payload | stderr |
|---|---|
| `"task": null` | `task: must be a content string or {"action": "clear"}, got null` |
| `task` absent | `task: required, a content string or {"action": "clear"}` |
| `"todo": null` | `todo: must be a content string or an object naming an action, got null` |
| `todo` absent | `todo: required, a content string or an object naming an action` |

Neither task message contains `todo` and neither todo message contains `task`,
so `assert field in result.stderr` does name the row's own field and the two
fields' predicates cannot be exchanged without redding. Matches the slice 1
code review's table.

### The `shape` rename

Confirmed harmless: the matrix above was run against the **final** submitted
shape (the string `shape` parameter, post-`FBT001` fix), not against the
bool-parameter version the report says it also ran. The rename touches
parametrize plumbing only; the assertions are untouched by it.

## Finding 1 (major, fixed) — "at both boundaries" was pinned at one

The slice's heading is *"`null` and an absent key are each a named error — at
the two boundaries only"*, and the mechanism it rests on is `main`'s
`if skill in ("handoff", "precompact"):` gate. The submitted table sends
`"skill": "handoff"` in all four rows, so it pins the rule at one boundary.

I added a fourth mutation of my own:

- **D** — the gate narrowed to `if skill == "handoff":`, i.e. a `precompact`
  call validates neither field and writes neither file.

Against the submitted table, **D reds nothing**: `pytest
tests/test_checkpoint.py` → 111 passed, `bats tests/hook-test.bats
tests/checkpoint.bats` → 159 ok, `pytest` (whole suite) → 201 passed. The
whole repository is green while `/handoff:precompact` silently stops writing
`handoff-task.md` and `handoff-todo.md` — which is precisely the wrap-up this
job exists to make reliable.

Why nothing catches it: all 17 `"skill": "precompact"` payloads in the file
carry `task_clear()` / `todo_keep()`, and their correct outcome is an empty
manifest with no file on disk — indistinguishable from the gate skipping the
work entirely. None uses `task_content` / `todo_content` / `todo_edit`.

Fix: a `skill` dimension over `["handoff", "precompact"]`, with each boundary's
own required fields (`rename` + `clear` for handoff, `compact` for precompact —
each forbidden at the other). Eight rows. Mutation D now reds the four
`precompact` rows and leaves the four `handoff` rows green, so the new
dimension is load-bearing rather than a doubled table.

This is why the count is 115 and not the 111 the dispatch expects. I judged the
alternative — recording it as a finding and leaving the hole open — worse: the
runbook names both boundaries in the slice's own heading, and the finding is
exactly the class ("a rule the slice claims that no row can red") the
write-then-mutate protocol exists to surface. Reverting is one decorator if the
orchestrator prefers to keep the count.

## Finding 2 (minor, fixed) — the two shapes pinned the same thing

Both rows of a field asserted only `field in result.stderr`. The field is
discriminated; the *shape* is not. Had `validate_task` reported "required" for
`null` and the got-null message for an absent key, both rows would still pass —
the two spellings would be conflated in the diagnostic while the table claimed
they were "distinct, named errors".

Fix: a third parametrize column, `reason` — `"got null"` for the `null` rows,
`"required"` for the `absent` rows. Both substrings are already in the
messages, neither appears in the other shape's message, and this is the file's
established idiom for pinning a reason alongside a field (`tests/test_checkpoint.py:700`
asserts `old_string` + `not found`, `:719` asserts `old_string` + `ambiguous`).

- **E** — the absent-key branches err with the got-null wording. Reds the four
  `absent` rows on the reason assertion (line 537), leaves the `null` rows
  green.

## My matrix against the fixed table (8 rows)

Every mutation single, off a clean tree, restore verified each time.

| Mutation | task_null | task_absent | todo_null | todo_absent |
|---|---|---|---|---|
| **A** — `null` accepted as an empty write | **RED** ×2 | green | **RED** ×2 | green |
| **B** — absent key falls back to a default | green | **RED** ×2 | green | **RED** ×2 |
| **C** — `main` writes the target before validating | **RED** ×2 | **RED** ×2 | **RED** ×2 | **RED** ×2 |
| **D** — gate narrowed to `handoff` | precompact only | precompact only | precompact only | precompact only |
| **E** — absent key reuses the got-null wording | green | **RED** ×2 | green | **RED** ×2 |

"×2" is both boundaries; "precompact only" is the precompact half red, the
handoff half green. A/B still disjoint after the fix. Failing-assertion lines
spot-checked so a row cannot be redding for the wrong reason: C fails at 539
(the exists assertion), E at 537 (the reason assertion), A and B at 534 (the
exit code).

## Reviewed as tests

- **Own-field naming** — yes, per the message table above.
- **Mutually distinct** — yes, now on three axes: field (A/B vs the message
  table), shape (E), boundary (D). Before the fix, only the field axis.
- **Target file per row** — correct: the task rows check `handoff-task.md`, the
  todo rows `handoff-todo.md`, confirmed by the paths in C's failure output
  rather than by reading.
- **File idiom** — `("field", "shape", "reason")` follows the `("field",
  "value")` tuple-parametrize form at `:1345` and `:1457`. Explicit `ids=`
  keeps the case names readable. Placement in the "Schema validation (FR2)"
  section, after `test_malformed_json_errors_naming_payload`, is right.
- **Stacked parametrize decorators are new to this file** (the other six sites
  are single). Standard pytest, and the composed ids read
  `[task_null-precompact]`; recorded as an observation, not a finding.
- **The docstring is the longest in the file** (only one other test carries one
  at all, `:1413`, one line). Kept: it carries the reason for the
  file-not-created assertion and for the boundary dimension, neither of which
  is legible from the assertions. The repo's convention is to match comment
  density; this is a deliberate exception on a parametrized rule, and
  docformatter accepts it.
- **Payload hygiene** — the field not under test carries a well-formed
  `task_clear()` / `todo_keep()`, so only the field under test is wrong. The
  `absent` shape is `del payload[field]`, an actual missing key, not an empty
  value.

## Regression guard — confirmed by name, individually

```
pytest tests/test_checkpoint.py -v -k test_autoname_manifest_present_empty_neither_file_touched
  → PASSED (1 passed, 114 deselected)
pytest tests/test_checkpoint.py -v -k test_restart_manifest_present_empty_neither_file_touched
  → PASSED (1 passed, 114 deselected)
```

Both green with the eight new rows in place, so the required-by-key-presence
rule does not over-reach into the two skills carrying neither field.

## Residual, not fixed — for the orchestrator

**No test asserts that `precompact` *applies* task/todo content.** The fix
above closes the gate's validation half: mutation D now reds. A narrower defect
— `validate_*` reached for precompact but `apply_*` skipped — would still slip,
because no precompact row in the file writes content and asserts a `W` manifest
line. Closing it means a precompact twin of
`test_task_write_creates_file_manifest_records_w` (`:640`), which is slice 1's
subject (the external contract's positives), not slice 2's, so I did not write
it. Cheapest form if wanted: parametrize those two existing write rows over
`skill` the same way.

Deliberately untouched, per scope: `scripts/checkpoint.py`; slice 3's action
vocabulary and `edit` key rows; slice 4's empty-body pairs; `bash-post.sh`;
both SKILL.md bodies; the docs.

## Verification

Checks run, and what each returned:

- `pytest tests/test_checkpoint.py -q` — **115 passed**.
- `pytest -q` (whole suite) — **205 passed, 11 deselected**.
- `bats tests/hook-test.bats tests/checkpoint.bats` — **159 ok**.
- The two named regression rows, run individually — **2 passed**.
- `ruff check scripts tests` — all checks passed.
- `ruff format --check scripts tests` — 11 files already formatted.
- `docformatter --check scripts/*.py tests/*.py` — clean.
- `mypy` — rc 0. `ty check` — all checks passed.
- `git diff scripts/checkpoint.py` — **0 lines**; `shasum` matches the
  pre-review baseline `ef465a86`.
- `git status --short` — only `tests/test_checkpoint.py` modified, plus the two
  untracked reports.

No commit made.
