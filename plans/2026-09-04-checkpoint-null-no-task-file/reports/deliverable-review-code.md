# Deliverable review — Layer 1, code + test

Range `e370aed..HEAD`. Files: `scripts/checkpoint.py`, `scripts/bash-post.sh`,
`tests/test_checkpoint.py`, `tests/checkpoint.bats`. Baseline:
`plans/2026-09-04-checkpoint-null-no-task-file/outline.md` plus the Phase 1 and
Phase 2 item bodies in `runbook.md`.

**Severity counts: 0 Critical, 3 Major, 9 Minor.**

## How this was verified

The live working tree was being mutated by another agent during the review
(`scripts/checkpoint.py` carried a third party's `_todo_edit_strings` mutation
mid-session, and one early probe of mine returned a result inconsistent with a
later clean run). Every claim below marked *verified* was re-established against
a pristine `git archive HEAD` export at `/tmp/claude/hr`, with `base.py` /
`bp.base` copies for save-mutate-run-restore. Baselines there: pytest
`128 passed`, `bats tests/checkpoint.bats` 23/23, `shellcheck -x
scripts/bash-post.sh` clean, `ruff check` clean.

**Process note for the lead, not a finding:** at one point I ran `git checkout --
scripts/checkpoint.py` on the live tree to restore my own mutation. `git status
--porcelain` was empty immediately afterwards, so nothing was clobbered at that
instant — but a concurrent mutation-check dispatch and a `git checkout --`
restore in the same tree can silently produce evidence gathered against
unmutated code, which is the exact failure the runbook's "Which restore belongs
to which situation" note was written about. Worth serialising.

## Conformance summary

The specified per-file changes all landed, and the enumerated deletions are
real deletions, not inversions. Confirmed gone:
`test_task_content_null_no_file_path_noop`,
`test_task_file_path_content_null_noop`,
`test_todo_content_null_no_file_path_noop`,
`test_todo_file_path_content_null_noop`,
`test_task_file_path_outside_claude_errors`,
`test_todo_file_path_outside_claude_errors`,
`test_todo_content_and_old_string_together_errors`,
`test_drifted_cwd_task_path_under_cwd_rejected`,
`test_task_with_old_string_new_string_errors`,
`test_todo_only_old_string_errors`, `test_todo_only_new_string_errors`,
`test_todo_null_untouched_list_left_alone`. No `file_path` occurrence survives
in either test file. The transient `[[tool.mypy.overrides]]` block Item 0.1 added
to `pyproject.toml` is gone, as Item 1.1 required.

Two deviations from the runbook's literal text, both improvements and both
already justified in-code:

- `bash-post.sh:53-59` reads `git ls-files`' **exit status** rather than the
  runbook's prescribed `[ -n "$(… ls-files …)" ]` single condition. The comment
  at :47-52 explains why (a failed command substitution does not trip `set -e`
  from inside `[ ]`, so the empty output would read as "never in the index").
  This is exactly what the review brief asked to check for, and it is right.
- Phase 2 specified three bats rows; five were delivered. The two extra
  (`D whose index cannot be read`, `one staged and one failed`) are both
  load-bearing — see the mutation matrix below — so this is justified excess.

`tests/checkpoint.bats`'s `handoff_payload()` fixture (`:212`) now emits
`task:{action:"clear"}, todo:{action:"keep"}`, which matches the Python
`task_clear()` / `todo_keep()` factories exactly. No duplication of semantics
and no contradiction; it is the one payload that suite needs and it is
constructed once.

### Mutation matrix (verified, on the clean export)

| Mutation | Result |
|---|---|
| `apply_todo`'s `action == "clear"` branch → `return []` | **128/128 still pass** — see Major 1 |
| `apply_task`'s `existed = path.is_file()` → `existed = True` | 45 failed, 83 passed |
| `apply_todo`'s `return [...] if existed else []` → unconditional `D` | 1 failed (`test_todo_write_no_items_never_existed_no_d`) |
| `bash-post.sh`: fold the `ls-files` exit status into one `[ -n "$(…)" ]` | bats row 22 reds, alone |
| `bash-post.sh`: drop the `else failed+=("$rel")` arm | bats rows 21 and 23 red |
| `bash-post.sh`: restore `2>/dev/null` on `git add` | bats rows 21 and 23 red |

Everything except row 1 discriminates. The `bash-post.sh` coverage is
non-vacuous throughout.

---

# Findings

## Major 1 — `todo: {"action": "clear"}` has zero test coverage

**File:** `tests/test_checkpoint.py` (no row exists; the natural home is beside
`test_task_clear_removes_pre_existing_file_manifest_records_d`, `:618`).
**SUT:** `scripts/checkpoint.py:386-390`.
**Axis:** coverage / conformance. **Verified.**

`{"action": "clear"}` is one of the four `todo` arms in the outline's accepted
shapes and is documented to the agent in `skills/handoff/SKILL.md:99` and
`:105-106` ("`{"action": "clear"}` removes that file"). It is the only way an
agent can explicitly retire the todo list. Nothing in either suite exercises it:
`grep '"action"' tests/test_checkpoint.py` shows `{"action": "clear"}` only
inside `task_clear()` and inside two *negative* rows; there is no `todo_clear()`
factory (the outline's own factory list — `task_content`, `task_clear`,
`todo_keep`, `todo_edit` — omits it, so the gap traces back to slice 0's
enumeration).

Mutation, on the clean export: replacing

```python
    if action == "clear":
        if not existed:
            return []
        path.unlink()
        return [f"D {HANDOFF_REL_TODO}"]
```

with `if action == "clear": return []` leaves the suite at **`128 passed in
16.64s`**. Under that mutation, `/handoff` with `"todo": {"action": "clear"}`
silently keeps a stale todo list on disk and stages nothing, and no test
notices.

The behaviour itself is correct today — verified by hand against the clean
export:

```
$ printf '{... "task":"## Current task\n\nreal\n","todo":{"action":"clear"}}' \
  | HANDOFF_ROOT=$R CLAUDE_CODE_SESSION_ID=s1 python3 scripts/checkpoint.py
rc=0
manifest: W .claude/handoff-task.md
          D .claude/handoff-todo.md
todo exists: no
```

What is missing is the evidence. The fix is the same pair shape slice 1 used for
`task`: a `todo_clear()` factory plus two rows over one fixture — pre-existing
file ⟹ removed and `D` recorded, never-existed file ⟹ nothing removed and **no**
`D` line — each carrying a live `W .claude/handoff-task.md` line so the absence
is a claim about the todo route rather than about an empty manifest (Item 1.2
residual 2's own rule).

## Major 2 — `task.action: required` / `todo.action: required` name no vocabulary

**File:** `scripts/checkpoint.py:278` and `:309`.
**Axis:** error signaling. **Verified.**

Every other message in the union names what to write instead —
`task: must be a content string or {"action": "clear"}, got null`,
`todo.action: must be "clear", "keep" or "edit", got "emty"`. The
missing-`action`-key branch does not:

```
$ echo '{"skill":"handoff",…,"task":{"file_path":"/x/.claude/handoff-task.md",
         "content":"## Current task\n\nbody\n"},"todo":null}' | … checkpoint.py
rc=2
handoff-checkpoint: task.action: required
```

That input is not a hypothetical. It is the **old payload shape**, and it is
precisely what a live session emits between slice 1 landing and a
`/reload-plugins` — the producer/consumer skew the outline's Verification
section calls out by name ("a live session emits the old payload into the new
validator, which rejects it"). The outline argues the rejection is "loud, which
is the right failure"; loud it is, but the agent reading `task.action: required`
learns neither that a bare string is now the content form nor that `clear` is
the only legal action. Both facts are one f-string away, and both appear
verbatim in the sibling messages already.

`tests/test_checkpoint.py:437-438` and `:442-443` pin this branch with
`reason="action: required"`, which is a substring any improved message would
still satisfy — so the test does not obstruct a fix, but nothing in the suite
requires the vocabulary either.

Suggested: `err("task.action", 'required — use a content string, or {"action":
"clear"}')`, and the corresponding three-action form for `todo`.

## Major 3 — an apply-time error leaves the filesystem mutated with no manifest and no sentinel

**File:** `scripts/checkpoint.py:505-509` (ordering), `:395-399` and `:345-347`
(the `err()` sites), `:509` (`write_manifest`, never reached).
**Axis:** functional correctness / robustness. **Verified.**

`main` applies the task before the todo, and `apply_todo` can `err()` — which
exits 2 immediately, before `write_manifest` and before `compose_sentinel`. So a
failed call has already rewritten or deleted `.claude/handoff-task.md`, and
nothing records it: no manifest ⟹ `bash-post.sh` never fires ⟹ the change is
never staged and never reported on either channel.

Two concrete runs against the clean export:

```
E) task: "## Current task\n\nNEW\n"   todo: {"action":"edit", old_string absent}
   pre-existing task file holds "OLD TASK"
   → handoff-checkpoint: todo.old_string: edit requested but
     .claude/handoff-todo.md does not exist        rc=2
   → task file now holds "## Current task\n\nNEW\n"
   → manifest present: no      sentinel present: no

F) task: {"action":"clear"}          todo: {"action":"edit", old_string not found}
   pre-existing task file holds "IMPORTANT TASK FRAME"
   → handoff-checkpoint: todo.old_string: not found in …/handoff-todo.md   rc=2
   → task exists: no           manifest present: no
```

The write half of this (E) is pre-existing. What decision 3 adds is (F): a
`clear` now **unlinks eagerly**, so a payload whose todo half is malformed
removes the task frame from the working tree while reporting a `todo.old_string`
error that says nothing about the task file. The frame is recoverable from the
index if a prior checkpoint staged it (it shows as an unstaged deletion in `git
status`), and a retry with a corrected payload re-converges — but the call that
reported failure has silently changed durable state, and the only user-facing
evidence is an unexplained `D` in `git status`.

Cheapest remedy consistent with the design: compute both files' manifest lines
before performing either mutation, or — since `apply_todo`'s two `err()` sites
are the only apply-time failures — hoist the `edit` preconditions
(file exists, `old_string` present and unambiguous) ahead of `apply_task`.
Alternatively, write the manifest for whatever was already applied before
`err()` exits, so the mutation at least reaches `bash-post.sh`.

No test covers this: `test_todo_edit_old_string_absent_errors` (`:806`) and
`test_todo_edit_requested_file_missing_errors` (`:843`) both send
`task_clear()` against a repo with no task file, so neither can observe it.

---

## Minor 1 — non-string `action` values render as Python reprs

`scripts/checkpoint.py:279`, `:310`. **Verified.**

```
{"action": true} → handoff-checkpoint: task.action: must be "clear", got "True"
{"action": 5}    → handoff-checkpoint: task.action: must be "clear", got "5"
```

`True` is not a JSON spelling, and the file already owns `_json_type()` for
exactly this — every neighbouring diagnostic says `got boolean` / `got number`.
An agent shown `got "True"` may reasonably try `"True"` next.

## Minor 2 — unknown keys are silently ignored, inside the action object and at top level

`scripts/checkpoint.py:274` and `:300` (`task.get("action")` /
`todo.get("action")` with no key-set check); `read_payload` (`:91`) for the top
level. **Verified.**

```
"todo": {"action":"keep","content":"## Remaining\n\n- x\n"}  → rc=0, content discarded
"task": {"action":"clear","content":"IMPORTANT UNSAVED"}      → rc=0, file removed
{… ,"tasks":"oops"}                                           → rc=0, key ignored
```

Decision 1's whole argument is that a mistyped *action* becomes a named schema
error rather than silently writing the wrong thing. A mistyped or superfluous
*key* still does not. The likeliest agent errors do fail loudly (the old
`{"file_path":…,"content":…}` shape hits `task.action: required`; `{"action":
"write","content":…}` hits `must be "clear", got "write"`), so this is a residual
rather than a hole — but rejecting unknown keys in the action objects is three
lines and closes the class properly.

## Minor 3 — `apply_todo` writes an empty body to disk before unlinking it

`scripts/checkpoint.py:391-403`. **Verified** (a watcher thread observed the file
appear and disappear for `"todo": "## Remaining\n"` against a never-existed
file; the manifest correctly ends up with no todo line).

`apply_task:361` tests `lib.is_empty_body(content)` *before* writing and so never
creates the file. `apply_todo` writes first and reads back. The docstring
justifies the read-back for the `edit` route — correctly, since an edit's result
exists only on disk — but the `write` route has the content in hand and could
take `apply_task`'s shape. As written, `apply_task`'s own docstring claim ("an
empty body is never written first") is true of `apply_task` and false of its
sibling, and a transient `.claude/handoff-todo.md` is briefly visible to
anything watching that directory.

## Minor 4 — a whitespace-only string body is written as content

`scripts/checkpoint.py:361` via `_checkpoint_lib.py:30-34`. **Verified**, and
**pre-existing / explicitly out of the outline's scope** (`is_empty_body` is
listed under **OUT**).

```
"task": "   "  → rc=0, manifest: W .claude/handoff-task.md
```

`is_empty_body` treats only the empty string as blank, so a line of spaces or a
tab counts as content. The resulting 3-byte task file passes
`load-handoff.sh`'s non-empty gate and gets injected as a frame. Noted here only
because the tagged union makes a bare string the ordinary content form, which
puts a hand-typed `" "` one keystroke closer than the old
`{"content": " ", "file_path": …}` did.

## Minor 5 — the "git's stderr now reaches the user" claim is unverified

`scripts/bash-post.sh:77-78`. **Not verified** — I did not test how the harness
surfaces a PostToolUse hook's stderr.

For a hook exiting 0, Claude Code generally surfaces stderr only in
debug/transcript mode, not in the ordinary conversation. If that holds, the
comment overstates: what actually carries the failure to both audiences is the
named path appended to `summary` and `agent_ctx` (which the bats rows do pin).
The `grep -q 'index.lock' "$err"` assertion in `tests/checkpoint.bats:405`
proves git's message reaches the *process's* stderr, not that anyone reads it.
Worth downgrading the comment to what is demonstrated.

## Minor 6 — the manifest is consumed even when every path failed to stage

`scripts/bash-post.sh:70`. Read-only observation.

`rm -f "$manifest"` runs unconditionally, so a stranded `index.lock` costs the
staging permanently: the report names the path but no remedy, and there is no
retry. This is consistent with the item's "report-only" design and with the
`bp-locked` bats row, which asserts the manifest is gone. Flagging it because
the agent-facing `additionalContext` says `failed to stage: <path>` and then
`Leave them staged; whatever commit lands next carries them.` is *suppressed*
(row 22 asserts that), leaving the agent told a path failed and nothing about
what to do. Appending `— re-stage with git add -f` would cost one clause.

## Minor 7 — `test_task_and_todo_both_written_manifest_lists_both` does not pin the manifest's length

`tests/test_checkpoint.py:962-984`. Two membership assertions over
`.splitlines()`, no `len(manifest) == 2`. A regression that appended a spurious
third line — the manifest is a list several routes append to — passes. The
`clear`/never-existed rows compensate with their broad `"handoff-task.md" not
in manifest` absence, so this is the one positive row where nothing bounds the
list.

## Minor 8 — `tests/checkpoint.bats` uses jq `test()` (regex) on paths containing `.`

`tests/checkpoint.bats:394, 396, 417, 419, 427, 429`. `test("failed to stage:
.claude/handoff-todo.md")` treats every `.` as "any character". The assertions
are still strong enough to have redded correctly under all three bash-post
mutations above, so this is cosmetic — but `test("…"; "x")` with escaped dots, or
plain `contains(…)`, says what is meant.

## Minor 9 — `test_todo_edit_requested_file_missing_errors` does not name the field

`tests/test_checkpoint.py:843-857`. Asserts `returncode == 2` and `"does not
exist" in result.stderr`, without asserting `old_string` or `todo` appears — its
two siblings (`:806`, `:825`) both assert `"old_string" in result.stderr`
alongside their own reason. The string `does not exist` is distinctive enough
today that the row is not vacuous, but it is the odd one out in a table whose
whole discipline (per slice 3's review, recorded in the runbook) is pinning the
field *and* the reason so two code paths reaching one channel cannot be
confused.

---

## Things checked and found sound

- `validate_task` / `validate_todo` run to completion **before** any
  `apply_*`, so a malformed `todo` never causes a `task` write. Pinned by
  `test_task_or_todo_null_or_absent_errors_naming_field`'s
  `assert not (repo / ".claude" / target).exists()`.
- `main`'s `if skill in ("handoff", "precompact")` gate is covered on both
  halves: validation by slice 2's `skill`-parametrized table, application by
  Item 1.2's `skill` parametrization of the two `_creates_file_manifest_records_w`
  rows. Narrowing the gate to `handoff` alone reds the latter.
- `apply_task`'s existence sampling and `apply_todo`'s conditional `D` both
  discriminate under mutation (45 and 1 failures respectively).
- `_todo_edit_strings`' type check (`:330-332`) closes the one arm of the union
  that previously exited 1 with a `TypeError` naming no field. Covered by two
  rows in the slice 3 table.
- `bash-post.sh` whitespace safety: `rel="${line#* }"` takes the whole
  remainder of the line, and `git add -f -- "$rel"` / `ls-files -- "$rel"` are
  quoted. The `${failed[*]}` space-join carries the same residual bound as the
  pre-existing `${staged[*]}` / `${deleted[*]}` joins, and the comment at
  `:81-85` states it rather than implying full coverage — which is what this
  repo's convention asks for.
- `bash-post.sh` idempotency: the manifest is the gate and is removed on
  consumption, so a second Bash call in the same turn is a silent no-op.
- `shellcheck -x scripts/bash-post.sh` and `ruff check` on both Python files:
  clean.
