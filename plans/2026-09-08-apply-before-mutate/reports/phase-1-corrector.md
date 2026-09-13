# Phase 1 checkpoint — the apply phase resolves before it mutates

Reviewed at `7608ee4` (tree clean at start and at hand-back). Subject: whether
Phase 1 discharges the six requirements the runbook mapped to it, and whether
the restructured `scripts/checkpoint.py` still integrates with everything
downstream of it.

**Verdict: no findings. Nothing applied, nothing to fix.** Every requirement in
the mapping table is discharged by named code and pinned by a named test. The
manifest's contract with `bash-post.sh` is byte-identical to what it was.
`write-stage.sh`'s shared emptiness test has not drifted. The failure path
leaves nothing behind.

Two phase-level claims that no per-slice review had checked are now
mutation-checked rather than observed passing — §1 FR7. Both discriminate.

The per-slice test review and code review are read and not re-derived: the red's
assertion structure, the rename's completeness, `keep`'s no-stat short-circuit
and the four GREEN mutations are settled there and are not revisited here.

## 1. Requirements coverage against the runbook's mapping table

### FR2 — a violation exits non-zero naming the offending field

**Code.** Three `err()` sites are reachable from the plan phase, all in
`plan_todo`'s subtree:

| site | message | position |
| --- | --- | --- |
| `scripts/checkpoint.py:402` | `{field}.old_string: not found in {path}` | `edited_body` |
| `scripts/checkpoint.py:404` | `{field}.old_string: ambiguous, {count} occurrences in {path}` | `edited_body` |
| `scripts/checkpoint.py:449` | `todo.old_string: edit requested but {HANDOFF_REL_TODO} does not exist` | `plan_todo`'s `edit` branch |

**Text unchanged, verified mechanically rather than by reading the patch.** The
whole-file `err(` call-site count is 42 before and 42 after; diffing the set of
`err(...)` literals between `7608ee4^` and `HEAD` returns exactly two additions,
both of which are the string `err(` appearing inside a *docstring*
(`checkpoint.py:396` "lets both err() sites run", `:438` "keeps its own explicit
file-absent err()"). No message literal moved. The validators
(`validate_task`, `validate_todo`, `_todo_edit_strings`) are untouched by the
commit.

**Tests.** `tests/test_checkpoint.py:961` (absent), `:989` (ambiguous), `:1017`
(file missing) — each asserting exit 2 and `todo.old_string` on stderr. The
test review tightened all three from a bare `old_string` substring to the dotted
name, which is what makes them FR2 assertions rather than assertions about any
message that happens to mention the key.

**Discharged.**

### FR4 — a call silent about the scratch list leaves it alone

**Code.** `scripts/checkpoint.py:442-444` — `keep` short-circuits to
`FilePlan("none", path, "", [])` ahead of `_plan_file`. `root /
HANDOFF_REL_TODO` is path composition and the `FilePlan` constructor takes no
stat, so the branch touches the filesystem not at all.

**Test.** `tests/test_checkpoint.py:1042`
`test_todo_keep_leaves_pre_existing_list_alone`, plus `:1126`
`test_precompact_nothing_touched_manifest_still_written_empty`, whose payload is
`task_clear()` + `todo_keep()`.

The short-circuit was mutation-checked in the code review (§3 there): deleting
it reds `test_todo_keep_leaves_pre_existing_list_alone` alone, because `keep`'s
body is `""` and `_plan_file` reads an empty body as a removal. Not repeated
here. The no-stat half is unobservable from behaviour and rests on the read,
which I confirmed independently.

**Discharged.**

### FR5 — the task/todo union's write semantics, observably unchanged

Walked each arm of both unions for an observable difference against
`7608ee4^`. There is exactly one, and it is the intended one.

| arm | old route | new route | observable delta |
| --- | --- | --- | --- |
| `task: write` | `write_text(content)`, or unlink-if-present when `is_empty_body(content)` | `_plan_file(…, content)` | none |
| `task: clear` | `action == "clear"` short-circuit to unlink-if-present | `body = ""` → `_plan_file`'s emptiness rule | none (`is_empty_body("")` is `True`: `"".split("\n") == [""]`, which the loop skips, returning `True`) |
| `todo: write` | write, then `is_empty_body(read_text())`, then unlink | `_plan_file(…, content)` | none — the round-trip through utf-8 returns the bytes just written |
| `todo: clear` | unlink-if-present | `body = ""` → same rule | none |
| `todo: keep` | `return []` before any stat | `FilePlan("none", …)` before any stat | none |
| `todo: edit` | `apply_edit` writes, then read-back emptiness test | `edited_body` returns, `_plan_file` tests the value | **only this**: on the failure path the task file now survives |

The `write`-to-empty case is where m3's code shape changed without changing
behaviour: old code created the file and immediately unlinked it, new code never
writes it. End state on disk and manifest lines are identical either way, which
is why the outline gave it no test of its own.

**Tests.** `:643` (task write, parametrized over both skills), `:677`/`:701`
(task clear, pre-existing and never-existed), `:818` (todo write), `:723`/`:753`
(todo clear), `:1042` (todo keep), `:890` (todo edit positive), `:1145` (both
halves written, manifest order pinned).

**Discharged.**

### FR6 — an empty resulting body is removed, on both halves

**Code.** `_plan_file` (`:409-420`) is the single rule: `lib.is_empty_body(body)`
against the **resolved body**, never a file read back after a write. Both
`plan_task` (`:428`) and `plan_todo` (`:454`) route through it. `existed =
path.is_file()` is sampled at `:416`, in the plan phase, so a `D` line records
only a removal that will actually happen.

**The matrix is complete.** Every route to an empty body has a row, and the one
empty cell is empty for a reason the suite itself pins:

| half | route to empty | pre-existing | never existed |
| --- | --- | --- | --- |
| task | `clear` | `:677` | `:701` |
| task | `write`, headings only | `:773` | `:795` |
| todo | `clear` | `:723` | `:753` |
| todo | `write`, no items | `:846` | `:868` |
| todo | `edit` to empty | `:926` (new this slice) | n/a — `edit` errors when the file is absent, and that error is `:1017` |

`:926` `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` is the
row the outline's decision 4 called for: the only route that reaches the
emptiness rule through a *computed* body rather than one the payload states
outright. It was green before the restructure and is therefore characterisation,
which the GREEN report's mutation (b) discharged — `if lib.is_empty_body(body):`
→ `if False:` reds it along with eleven others that read the same rule.

**Discharged, on both halves.**

### FR7 — everything the checkpoint writes reaches the manifest

Three distinct claims. All three are now pinned, and the two that were merely
*observed* are mutation-checked here.

**(a) The lines and their order.** `main()` (`:571`) concatenates
`task_plan.manifest_lines + todo_plan.manifest_lines`. Pinned by `:890`'s exact
list equality `["D .claude/handoff-task.md", "W .claude/handoff-todo.md"]` and
`:1145`'s `["W …task.md", "W …todo.md"]`. Mutation-checked by the GREEN report's
check (c).

**(b) `write_manifest` stays unconditional.** `main():572` calls it outside the
`if skill in ("handoff", "precompact")` block, so a `rename`-only or `restart`
call still leaves the empty file `bash-post.sh` gates on.

> **Mutation check, run here.** `write_manifest(root, manifest_lines)` →
> `if manifest_lines:\n        write_manifest(root, manifest_lines)`.
> Result: `4 failed, 135 passed` — `test_rename_only_manifest_present_empty_sentinel_written`,
> `test_precompact_nothing_touched_manifest_still_written_empty`,
> `test_autoname_manifest_present_empty_neither_file_touched`,
> `test_restart_manifest_present_empty_neither_file_touched`, each on
> `assert manifest.is_file()`. Exactly the four empty-manifest rows and nothing
> else. The claim discriminates, and the `precompact` row specifically covers a
> *boundary* skill whose two plans are both `"none"` — the case the restructure
> could have regressed.

**(c) A wrap-up that fails writes no manifest because it wrote nothing.** The
three negatives assert `not (repo / ".claude" / "checkpoint-manifest").exists()`.
That assertion is green before and after the restructure, so it had never been
shown to discriminate.

> **Mutation check, run here.** `    manifest_lines: list[str] = []` →
> `    manifest_lines: list[str] = []\n    write_manifest(root, manifest_lines)`,
> making the failure path leave an empty manifest behind.
> Result: `3 failed, 136 passed` — the three surviving-task-file negatives
> alone, each on the no-manifest assertion. It discriminates.

Both mutations were applied in place by exact string replacement and inverted by
the reverse replacement; each restore proved by an empty
`git diff --stat scripts/checkpoint.py` before the next step. No backup file was
written anywhere.

**Discharged.**

### NFR1 — no git, no tmux in the checkpoint

`grep -n 'subprocess\|tmux\|os.system\|popen' scripts/checkpoint.py` returns one
call site: `subprocess.run` at `:500`, inside `_read_back_drive`, which shells
out to `bash` for `handoff_drive_read`. Pre-existing, untouched by the commit,
and not on the plan/apply path. No `git` invocation anywhere in the module.

**No new subprocess.** `_plan_file`, `plan_task`, `plan_todo`, `edited_body`,
`apply_plan` and `write_manifest` spawn nothing.

**No new import, stated precisely.** Diffing the import block against
`7608ee4^` gives one line: `from typing import Any, NamedTuple, NoReturn, cast`
→ `from typing import Any, Literal, NamedTuple, NoReturn, cast`. That is a name
added to an existing `from`-import of an already-loaded stdlib module, not a new
module dependency — nothing new is loaded at runtime and no cost is added to
NFR2's hot path. Stating it rather than leaving it silent, since "no new import"
read literally would be false.

**Discharged.**

## 2. Integration beyond the changed module

### `scripts/bash-post.sh` — the manifest consumer

**Line format: byte-identical.** `bash-post.sh` splits each line on its first
space (`op="${line%% *}"`, `rel="${line#* }"`) and dispatches on `op == "D"`.
`_plan_file` composes `f"D {rel}"` and `f"W {rel}"` where `rel` is the caller's
`HANDOFF_REL_TASK` / `HANDOFF_REL_TODO` — the same two constants
(`checkpoint.py:45-46`, `.claude/handoff-task.md` and `.claude/handoff-todo.md`)
the old code interpolated inline at `:406`, `:408`, `:431`, `:443`, `:444`. The
restructure moved the interpolation from five sites to two and parameterised the
path over `rel`; the emitted bytes are unchanged. `tests/checkpoint.bats:329`,
`:361`, `:391` hand-write exactly those strings as fixtures, so both sides of the
seam still name the same two literals.

**Ordering.** `bash-post.sh` iterates the manifest top to bottom and stages each
path independently, so task-before-todo is not something it depends on — but it
is pinned anyway by `:890` and `:1145`, and `main()` produces it by
concatenation in that order.

**The always-written empty manifest.** `bash-post.sh`'s fast-exit gate is
`[ -f "$raw_cwd/.claude/checkpoint-manifest" ]` — the file's *presence*, not its
contents. `write_manifest` writes `""` for zero lines, so the file exists with
size 0 and the gate fires; the `while read` loop then produces zero entries and
the hook emits `staged 0, deleted 0` with the "Leave them staged" clause
correctly suppressed. `tests/checkpoint.bats:283` (`bash-post: empty manifest
(rename-only checkpoint call) -> consumed, sentinel untouched`) covers the
consumer side; §1 FR7(b)'s mutation covers the producer side. Unaffected by the
restructure and verified still true.

**Failure path, from the consumer's view.** This is where the change improves
what `bash-post.sh` sees. Before: a malformed todo half deleted
`handoff-task.md` and wrote no manifest, so the hook fast-exited and the
deletion went unstaged and unreported. After: nothing is deleted, so there is
nothing for the hook to miss. No change to `bash-post.sh` is owed.

### `scripts/write-stage.sh` — the shared emptiness test

`write-stage.sh` reaches `is_empty_body` through
`python3 _checkpoint_lib.py --is-empty-body < "$target"`, i.e. the `_cli` entry
point at `_checkpoint_lib.py:220-230`. `scripts/_checkpoint_lib.py` is **not in
the commit** (`git show --stat 7608ee4` lists only `scripts/checkpoint.py`,
`tests/test_checkpoint.py` and four reports), so `is_empty_body`'s body at
`:23-34` is byte-for-byte what it was.

The two writers therefore cannot have drifted: `checkpoint.py` calls the
function in-process at `_plan_file:417` and `write-stage.sh` calls the same
function through the CLI. What moved is *when* `checkpoint.py` calls it — on a
resolved body instead of a file it wrote first — which is invisible to the CLI
path, since `write-stage.sh` was always feeding it the contents of a file the
agent had already written directly (FR4).

(`CLAUDE.md`'s account of *when* that call happens is now stale. That is item
2.1's, named in the dispatch's scope-out, and is not reported as a finding.)

## 3. Lifecycle and state hygiene on the failure path

**Every filesystem write in the module, enumerated** (`grep -n
'write_text\|unlink\|mkdir\|touch()\|rmtree' scripts/checkpoint.py`):

| line | write | position relative to the plan phase |
| --- | --- | --- |
| `:465` `plan.path.write_text` | `apply_plan`, write route | after both plans exist |
| `:467` `plan.path.unlink` | `apply_plan`, remove route | after both plans exist |
| `:476` `checkpoint-manifest` `write_text` | `write_manifest` | after both applies |
| `:524` `drive_path.write_text` | `compose_sentinel` | after the manifest |
| `:528` `drive_path.unlink` | `compose_sentinel`'s read-back failure | after the manifest |

Nothing writes during validation or during planning. So a `SystemExit(2)` raised
by any of the three plan-phase `err()` sites leaves: **no partial file** (neither
half has been applied), **no manifest** (`write_manifest` is three statements
further down), **no sentinel** (`compose_sentinel` is further down still), and
**no temp file** — `grep 'tempfile\|NamedTemporary\|mkstemp\|open(\|\.close()'`
returns nothing, every access going through `Path.read_text` / `write_text` /
`unlink`, which own their handles. No stateful object can be stranded by the
exit, because none is ever held.

**Ordering of `write_manifest` against `compose_sentinel`.** Manifest first, and
that is load-bearing rather than incidental: `compose_sentinel`'s read-back
`err()` (`:529`) fires after both halves are applied, so with the reverse
ordering a read-back failure would strand two unstaged mutations. As written,
the mutations are recorded and `bash-post.sh` stages them, and the sentinel is
unlinked so nothing is armed — a coherent end state.

*Observation, not a finding:* that ordering is unpinned by any test. No row
makes the read-back fail — `read_back_drive` at `test_checkpoint.py:160` is only
ever asserted true. It is unreachable from the production entry point: the
sentinel's grammar is composed from a payload that `validate_continuation` has
already forbidden a leading `/` and a second line on, so only a composer/parser
code drift can trigger it, which is exactly what the `err()` exists to detect.
Reaching it from a test would mean faking `_lib.sh`. Out of scope (the sentinel
composer is scope-OUT), and correctly left alone.

**Ordering against the directive output.** `compose_directives` (`:574`) and
`print_output` (`:576`) both run after the manifest. `compose_directives` reaches
`lib.memory_directive`, which does spawn `git config` subprocesses — those can
raise if `git` is absent, producing a traceback and exit 1 *after* the applies
and the manifest. Pre-existing, unchanged by this commit, and benign for the
same reason as the sentinel case: the mutations are already recorded and staged.
Not widened here.

**TOCTOU, stated honestly.** The window between sampling `existed`
(`_plan_file:416`) and acting on it (`apply_plan:467`) is wider than it was —
`plan_todo` now runs in between, and for an `edit` that includes a file read. A
concurrent removal in that window makes `unlink()` raise `FileNotFoundError`,
which is an `OSError` and therefore sits inside the exclusion the outline states
by name ("An `OSError` from the filesystem is outside the guarantee"). Both files
have a controlled writer — `handoff-task.md` is checkpoint-only (FR3, enforced by
`write-guard.sh`) and `handoff-todo.md` is agent-edited through `write-stage.sh`
(FR4) — so the window needs two checkpoints in flight in one repo to matter.
`missing_ok=True` would be the wrong fix: it would let the `D` line claim a
removal this process did not perform, which is the exact property
`_plan_file`'s docstring commits to. Leaving it to raise is correct.

## 4. Out of reach, and the two stated exclusions

Named so their absence reads as deliberate rather than as gaps, per the
runbook's own list: **FR1** (one entry point), **FR3** (the task file's write
guard), **FR8** and **FR9** (the sentinel and the directives, composed after the
apply and untouched), **FR12** (the gitlore submodule registration),
**FR-G**, **FR-H**, **NFR2**, **NFR3**. Confirmed unreachable by this change:
none of them is named by any line the commit touches.

The two explicit exclusions, confirmed present and confirmed not widened:

1. An `OSError` from the filesystem strands a half-applied wrap-up exactly as
   today — §3 above walks the four places one can arise and shows the change
   moves one of them (`edited_body`'s `read_text`) *into* the plan phase, which
   is a strict improvement, and moves none the other way.
2. `compose_sentinel`'s read-back `err()` still fires after both halves are
   applied, with `write_manifest` already run. In the design, and §3 states why
   the ordering is the right one.

Neither is reported as a finding.

## 5. The test body as a whole

`tests/test_checkpoint.py` holds 95 `def test_` functions collecting to 139 rows.
Judged for requirements coverage rather than per-assertion (that was the test
review's subject):

- **No requirement in the mapping table is unpinned.** Each of the six has at
  least one row named in §1, and FR5's and FR6's matrices are enumerated there
  in full with every cell either filled or accounted for.
- **No row in the slice is vacuous.** The three negatives red on
  `assert task_path.is_file()` against unchanged code (test review, recorded
  verbatim). The two characterisation rows earn their evidence by the GREEN
  report's mutations (b) and (c). The two FR7 claims that neither covered are
  mutation-checked in §1 above. Every assertion the slice added has now been
  shown to discriminate.
- **The fixture discipline holds.** All five rows carry a byte-identical task
  half (`task_path`, `task_before = "## Current task\n\nrecognisable\n"`, the
  write, and `"task": task_clear()`), differing only in the todo `old_string`'s
  match count — zero, two, no-file, one, one-that-empties. That is the
  one-fixture-one-trigger shape the recall artifact's `green-is-not-evidence`
  entry calls for.

## Verification

- `git status --porcelain` empty at start and before writing this report.
- `pytest tests/test_checkpoint.py -q` → `139 passed`.
- Mutation: early unconditional `write_manifest` → `3 failed, 136 passed`, the
  three negatives on their no-manifest assertion. Inverted; `git diff --stat
  scripts/checkpoint.py` empty.
- Mutation: `write_manifest` made conditional → `4 failed, 135 passed`, the four
  empty-manifest rows on `assert manifest.is_file()`. Inverted; `git diff
  --stat scripts/checkpoint.py` empty.
- `err(` call-site count 42 before and 42 after; `err(...)` literal diff shows
  only two docstring occurrences added.
- Import diff against `7608ee4^`: one line, `Literal` added to the existing
  `from typing import`.
- `grep 'subprocess\|tmux\|os.system\|popen' scripts/checkpoint.py` → one
  pre-existing site (`:500`).
- `grep 'tempfile\|NamedTemporary\|mkstemp\|open(\|\.close()'` → nothing.
- `git show --stat 7608ee4` confirms `scripts/_checkpoint_lib.py`,
  `scripts/bash-post.sh` and `scripts/write-stage.sh` are not in the commit.
- `just precommit` green: jq manifests, `shellcheck -x`, `ruff check`,
  `ruff format --check`, `docformatter --check`, `mypy`, `ty check`,
  `bats` (164 ok), `pytest` (229 passed, 11 deselected).

No live mutation. No commit. No UNFIXABLE items. Tree at hand-back holds this
report and nothing else.
