# Item 1.1, slice 1 — code review

Reviewed at `86d7024` (tree clean at start). Scope: `scripts/checkpoint.py`'s
plan/apply split and the rename's completeness across the repository.

**Verdict: one finding, fixed.** The guarantee holds as stated, the contract is
matched field for field, and the mutation evidence discriminates. The single
defect was a vestigial `apply_todo` citation in a test docstring the rename
missed.

## 1. The guarantee holds

Every `err()` reachable from the two halves fires before either file is
touched. Walked rather than taken from the GREEN report.

`main()` (`scripts/checkpoint.py:565-573`) is the whole ordering:

```
validate_task / validate_todo   ← every schema err()
plan_task                       ← no err() at all
plan_todo                       ← err() at :449, and edited_body's at :402/:404
apply_plan(task_plan)           ← first filesystem mutation
apply_plan(todo_plan)
write_manifest
```

Enumerated `err()` sites reachable from the plan phase — three, all of them in
`plan_todo`'s subtree:

| site | reached from | fires |
| --- | --- | --- |
| `checkpoint.py:449` `todo.old_string` "does not exist" | `plan_todo`'s `edit` branch | plan phase |
| `checkpoint.py:402` `.old_string` "not found in" | `edited_body` | plan phase |
| `checkpoint.py:404` `.old_string` "ambiguous, N occurrences" | `edited_body` | plan phase |

`plan_task` (`:423-430`) has none — `clear` resolves to `""` and reaches
removal through `_plan_file`'s own rule, exactly as contracted. `_plan_file`
(`:409-420`) has none. `apply_plan` (`:459-467`) has none: a `write` branch,
a `remove` branch, and no `else`. `write_manifest` (`:470-476`) has none.

So the only way out of the two halves without reaching `write_manifest` is a
`SystemExit(2)` raised while both files are still untouched — FR7's restated
form ("a wrap-up that fails writes no manifest because it wrote nothing")
holds, and `bash-post.sh`'s presence gate correctly sees nothing.

`compose_sentinel`'s read-back `err()` (`:529`) still fires after both
applies. In the design, named by the runbook, and `write_manifest` precedes
it — so the mutation is recorded and staged. Not a finding.

Residual, already named as outside the guarantee and confirmed not widened
here: an `OSError`/`UnicodeDecodeError` from `path.read_text()` inside
`edited_body`, or from `write_text`/`unlink` inside `apply_plan`. The first is
now in the plan phase, which is a strict improvement over the old
`apply_edit`; the second is the stranding case the outline excludes.

## 2. The rename — one finding, fixed

Re-derived with `rg -n 'apply_edit|apply_task|apply_todo'` over the whole
repository. The sweep found one live hit beyond the two permitted:

**Finding (fixed) — `tests/test_checkpoint.py:929`, a vestigial citation of a
function that no longer exists.** The slice's own new row,
`test_todo_edit_emptying_the_list_removes_it_manifest_records_d`, opened with:

> The edit-to-empty route: `apply_todo`'s docstring names this as the whole
> reason its emptiness test reads the file rather than a value it already
> holds.

Both halves are dead. `apply_todo` is retired, and the rationale it cited is
the one this change deletes — `plan_todo`'s docstring does not name it, and
correctly so, since the emptiness test no longer reads a file. A reader
following that pointer lands nowhere. It is prose, not an assertion, so fixing
it does not touch what the test review settled.

Replaced with a present-tense statement of what the row pins:

```
"""The edit-to-empty route: an `edit` whose replacement leaves the body
empty removes the file and records its `D` (FR6).

The only route to removal that reaches the emptiness rule through a computed
body rather than one the payload states outright, and the one the `write`
rows beside it do not cover.

Carries the same pre-existing-task-file fixture as its four siblings, …
"""
```

The second paragraph is what makes the row's existence self-justifying, which
was the outline's decision 4 ("the behavior whose rationale this change
deletes is pinned rather than assumed") — previously carried only by the
pointer that has now gone stale.

After the fix the sweep returns exactly the two permitted hits and nothing
else:

- `docs/design.md:240` — item 2.1's, Phase 2
- `docs/changelog/2026-09-07-the-payload-names-its-actions.md:53` — frozen
  write-time record

No alias, no back-compat wrapper, no `apply_edit`/`apply_task`/`apply_todo`
definition or call anywhere in `scripts/`, `bin/`, `hooks/` or `tests/`.
`docformatter --in-place` was needed on the rewritten docstring (same lint gap
the RED and GREEN phases each hit).

## 3. FR4's no-stat guarantee for `keep` — confirmed, and mutation-checked

Read the path rather than taking the report's claim (`checkpoint.py:442-444`):

```python
path = root / HANDOFF_REL_TODO
if action == "keep":
    return FilePlan("none", path, "", [])
```

`root / HANDOFF_REL_TODO` is pure path composition — no stat — and the
`FilePlan` constructor takes none. The short-circuit precedes every other
branch, so `keep` reaches neither `path.is_file()` (the `edit` precondition)
nor `_plan_file`'s own sample. Nothing on the path touches the filesystem.

The no-stat half is unobservable from behaviour, so it rests on the read. The
short-circuit itself is observable, and the contract names the row that would
red if it ever fell through. **Re-derived rather than trusted** — the GREEN
report ran four mutations and this was not among them, and it is the one that
underwrites §4's exception:

| mutation | result |
| --- | --- |
| delete the two-line `keep` short-circuit so it falls through to `_plan_file` | `1 failed, 138 passed` — `test_todo_keep_leaves_pre_existing_list_alone` alone, on `read_text() == before`, raising `FileNotFoundError`: `keep`'s content is `""`, the resolver reads it as a removal, and the pre-existing list is unlinked |

Exactly the row the contract predicts, and it reds alone. Restored by
rewriting the original text in the same Bash call; proven by an empty
`git diff --stat scripts/checkpoint.py` and an empty `git status --porcelain`
before continuing. No backup file was staged anywhere.

## 4. `_plan_file` is the single producer

`rg -n 'FilePlan\('` gives four construction sites:

| line | shape | in |
| --- | --- | --- |
| `:418` | `("none", path, "", [])` | `_plan_file`, removal route, file absent |
| `:419` | `("remove", path, "", [f"D {rel}"])` | `_plan_file`, removal route, file present |
| `:420` | `("write", path, body, [f"W {rel}"])` | `_plan_file`, write route |
| `:444` | `("none", path, "", [])` | `plan_todo`'s `keep` short-circuit |

Three of the four are in `_plan_file`, and they are the only places a `D` or a
`W` line is composed — so a plan cannot claim a `D` it will not perform, since
`act == "remove"` and the `D` line are produced by the same expression. The
fourth is the contract's deliberate exception, and §3 shows it is guarded and
cannot be folded in: routing `keep` through `_plan_file` is not a
simplification, it is the defect.

`FilePlan.manifest_lines` is a plain `list[str]` inside a `NamedTuple`, so the
record is frozen but that field is not. Per the contract ("`write_manifest`'s
signature does not move"), and nothing mutates a plan's list — `main()`
concatenates into a new one.

## 5. Docstrings

`apply_todo`'s old docstring described two asymmetries against `apply_task`
(where existence is sampled, and that the emptiness test reads the file rather
than `content`). Both are gone from the code, and both are gone from the
prose.

- `FilePlan` (`:378-384`) — states the frozen record and the single-producer
  rule. No FR cite, and none is owed: it describes a shape, not a rule.
- `edited_body` (`:388-394`) — cites FR2, and states why it returns rather
  than writes ("lets both `err()` sites run while a plan is still being
  resolved, ahead of any write"). Correct and load-bearing.
- `_plan_file` (`:409-415`) — cites FR5/FR6/FR7, states the emptiness rule and
  that existence is sampled "here, before anything is written, so a `D` line
  records only a removal that will actually happen". This is the shared rule
  both halves now obey, which is what replaces the asymmetry.
- `plan_task` (`:423-427`) — cites FR5/FR6/FR7; states `clear`'s routing
  through the shared rule.
- `plan_todo` (`:431-441`) — cites FR5/FR6/FR7 and FR4; names the `keep`
  short-circuit *and its reason* ("must not reach a rule that reads an absent
  body as a removal"), and names the second stat as deliberate ("a precondition
  check and an existence sample are different questions").
- `apply_plan` (`:459-463`) — "No failure branch", which is the guarantee's
  other half.

`D3` is re-typed nowhere: `rg 'D3' scripts/ tests/` returns nothing. (The
runbook's own text carries it; the code does not.)

One prose check worth stating because it is the thing that rots: `plan_todo`'s
"the stat `_plan_file` then takes is deliberate" is true of the code as
written — `path.is_file()` at `:449`'s guard and `_plan_file`'s own
`path.is_file()` at `:416` are two calls, not one memoized value.

## 6. The mutation evidence

Read all four checks in the GREEN report and judged each against the question
that matters: could the predicted row's own fixture satisfy the guard either
way, leaving the check green under the mutation and proving nothing?

**(a) Ordering** — `apply_plan(task_plan)` hoisted above `plan_todo`. Reds the
three negatives on `assert task_path.is_file()`, `3 failed, 136 passed`.
Discriminates: each of the three fixtures writes a real task file and sends
`task_clear()`, so the mutation deletes a file the assertion then demands. The
fixture cannot satisfy the guard either way — the assertion is about a file the
mutation removes. Sound, and it is the check that speaks directly to the item's
title.

**(b) Empty-body route** — `if lib.is_empty_body(body):` → `if False:`. Reds 12
including the target. Discriminates: the target row asserts
`not (…/handoff-todo.md).exists()`, and the mutation forces the write route, so
the file survives. The eleven collateral reds are the same rule reaching
`task_clear()`'s empty body — consistent with the mechanism, and the report
says so rather than glossing it.

**(c) Positive's second claim** — manifest concatenation reduced to
`todo_plan.manifest_lines`. Reds 11 including the target on its exact-two-lines
assertion. Discriminates: `['W .claude/handoff-todo.md']` against the expected
two lines. This is the check that pins the contract's stated line order
(task's first, then todo's) — a reversal would red the same assertion.

**(d) Existence sampling** — the never-existed branch made to emit
`[f"D {rel}"]` while keeping `act == "none"`. Reds 6.

Check (d)'s claim about the positive staying green is the one the dispatch
singled out, and it is **correct for the stated reason** — re-derived here
rather than accepted:

- `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` writes
  the task file in its fixture before running, so `plan_task`'s empty body
  reaches `_plan_file` with `existed == True` and returns at `:419`, which the
  mutation does not touch. Its todo half is a non-empty `edit`, so it takes the
  write route at `:420`, also untouched. The mutation is unobservable there.
- `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` likewise
  pre-writes both files, so both halves take `:419`.

So the positive is green because both its halves take the `existed == True`
branch, not because the assertion is weak. The four named reds are genuinely
the never-existed rows, and the report says it verified that against their
bodies rather than their names — which the `make_repo`-with-no-pre-write shape
confirms.

The one gap in the four, now closed: nothing mutation-checked FR4's `keep`
short-circuit, which is the contract's own named guard row and the exception
to §4's single-producer rule. §3 above supplies it.

## 7. Process note — one edit pass (record only, no rework)

The GREEN report states the implementation was made to pass in one edit pass
(`3 failed, 136 passed` → `139 passed`) rather than one test at a time.
Assessed the resulting code for over- or under-growth; **found neither.**

- Against the `Interfaces:` block: every name, signature, field and type
  matches, with no extras. No helper beyond `_plan_file`, no parameter that is
  not read, no field that is not consumed.
- No speculative generality. `apply_plan` has a `write` branch, a `remove`
  branch and no `else` — the `"none"` shape falls out of the `Literal` rather
  than being handled. `_plan_file` takes `rel` beside `path` rather than
  deriving it, which is necessary: the manifest line is repo-relative and
  `path` is absolute.
- No under-growth. Every arm of both unions has a route (`task`: `write`,
  `clear`; `todo`: `write`, `clear`, `keep`, `edit`), and the mutation set
  plus §3 shows each is reached by a row that discriminates.
- One stylistic asymmetry, deliberately not flagged as a defect: `plan_task`
  resolves `clear` with a conditional expression (`body = "" if action ==
  "clear" else content`) while `plan_todo` uses an `if`/`elif`/`else` chain
  whose `clear` arm sets `body = ""` — redundant, since `validate_todo` already
  returns `""` as the content for `clear`. Keeping it explicit is right: it
  makes `plan_todo` independent of which filler `validate_todo` happens to
  return, and it mirrors `plan_task`. Not a change to make.

The one thing the single pass did cost is §2's finding: a docstring written in
the RED phase against the pre-change code, carried into GREEN unrevised
because the pass was driven by the suite going green rather than by reading
each touched docstring against the new shape. That is the characteristic
failure mode of a one-pass GREEN, and it is exactly one line of prose here.

## Nothing else flagged

Confirmed untouched and left alone, per the dispatch's scope-out:
`validate_task` / `validate_todo` / `_todo_edit_strings` and every message
string in them; `scripts/_checkpoint_lib.py`; `scripts/bash-post.sh`;
`scripts/write-stage.sh`; the manifest format; the sentinel composer; the
directive composition; `docs/design.md:240`; the 2026-09-07 changelog entry;
`tests/test_checkpoint.py:603`'s `D2` citation.

No UNFIXABLE items. No refactoring flagged — no module split or new
abstraction is warranted; the plan/apply seam is the abstraction the item
asked for and it landed at the right size.

## Verification

- `rg -n 'apply_edit|apply_task|apply_todo'` over `scripts/ tests/ bin/ hooks/
  docs/ *.md` → exactly the two permitted hits.
- `rg 'D3' scripts/ tests/` → nothing.
- Mutation check on `keep`'s short-circuit → `1 failed, 138 passed`, the
  predicted row alone; restored, `git diff --stat scripts/checkpoint.py` empty,
  `git status --porcelain` empty.
- `just precommit` green: jq manifests (3), `shellcheck -x`, `ruff check`,
  `ruff format --check` (11 files), `docformatter --check`, `mypy`, `ty
  check`, `bats` (164 ok), `pytest` (229 passed, 11 deselected).

Tree at hand-back holds one fix (`tests/test_checkpoint.py`'s docstring) and
this report. No live mutation, no commit.
