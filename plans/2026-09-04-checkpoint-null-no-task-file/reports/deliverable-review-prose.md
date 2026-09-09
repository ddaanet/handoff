# Deliverable review — Layer 1, prose + config

Range `e370aed..HEAD`. Files reviewed: `CLAUDE.md`, `docs/design.md`,
`docs/changelog.md`, `docs/changelog/2026-09-07-the-payload-names-its-actions.md`,
`docs/changelog/2026-07-27-content-null-is-a-no-op.md`, `skills/handoff/SKILL.md`,
`skills/precompact/SKILL.md`. Baseline:
`plans/2026-09-04-checkpoint-null-no-task-file/outline.md`.

**Counts: Critical 0, Major 1, Minor 6.** (Plus one out-of-scope observation.)

---

## Major

### M1 — `skills/handoff/SKILL.md:81,104-109` and `skills/precompact/SKILL.md:49,80-84` — determinism / actionability

The `todo` field has no stated answer for the negative branch, and the two
candidate answers have opposite effects.

Step 3's decision bullet gives only the positive branch:

> `skills/handoff/SKILL.md:81` — "**Todo content** — whether there are open
> decisions still to make, or a task list with open items in play; **if so**,
> draft the todo content using the template below"

`skills/precompact/SKILL.md:49` is the same shape ("Decide the task snapshot
and, **when** open decisions or a task list with open items are in play, the
todo content").

The explanatory paragraph then describes the actions mechanically, and names
the negative branch for `task` only:

> `skills/handoff/SKILL.md:105-108` — "`{"action": "clear"}` removes that
> file — **for `task`, this is how a boundary with nothing to carry says so**.
> `{"action": "keep"}` leaves the list untouched and `{"action": "edit", …}`
> strikes a finished item without regenerating it — both `todo` only."

So for `task`, "nothing to carry ⟹ `clear`" is explicit. For `todo`, nothing
says which action a boundary with no todo content sends. Two agents will split:

- `{"action": "keep"}` — reading "nothing to say about the list", which is
  FR4-correct and is the direct heir of the deleted `null` no-op rule.
- `{"action": "clear"}` — reading "no open items remain, so the list is
  finished", which is correct when the remainder is genuinely empty.

Verified against `scripts/checkpoint.py:382-390`: these are not near-neighbours.
`keep` returns `[]` "without touching the file, not even to stat it"; `clear`
unlinks it and emits `D`. One preserves a possibly-stale list into the next
session; the other deletes an open remainder.

The preserve-a-stale-list outcome is the exact defect class this change was
made to eliminate for `task` — the changelog entry
(`docs/changelog/2026-09-07-the-payload-names-its-actions.md:16-20`) frames it
as "One spelling, two fields, opposite correct meanings". The union removed the
shared *spelling*; the skill prose has not yet supplied the missing *decision
rule* on the `todo` side, so the ambiguity survives one level up, in the
producer rather than the schema.

Note the outline anticipated the replacement would "name the four actions
instead of teaching a rule" — which is what happened. The gap is that naming
the actions is sufficient for `task` (two arms, one obviously the default) and
insufficient for `todo` (four arms, two of which both plausibly answer "no todo
content").

Concretely: the paragraph needs one clause tying `keep` to "this call says
nothing about the list" and `clear` to "the list is empty / every item landed",
or the step-3 bullet needs its `if not` branch.

---

## Minor

### m1 — `skills/handoff/SKILL.md:107`, `skills/precompact/SKILL.md:82-83` — constraint precision

`{"action": "edit", …}` is described without either precondition the validator
enforces. `scripts/checkpoint.py:394-399` errs when the file is absent
(`todo.old_string: edit requested but .claude/handoff-todo.md does not exist`),
and `apply_edit` (`scripts/checkpoint.py:432-441`) errs when `old_string` is
absent (`not found in …`) or ambiguous (`ambiguous, N occurrences in …`). All
three are covered by tests (`tests/test_checkpoint.py:806,825,843`). Recoverable
— step 4 tells the agent "A non-zero exit names the offending field on stderr —
fix the payload and retry" — so this costs a round trip, not a defect.

### m2 — `skills/handoff/SKILL.md:104-109`, `skills/precompact/SKILL.md:80-84` — functional completeness

FR6 is no longer stated anywhere in either skill body. The deleted sentence
carried it obliquely ("the checkpoint decides absence from content, not from a
wipe"); the replacement names `clear` as the only removal route. But
`apply_task`/`apply_todo` also remove a file whose drafted body is empty under
`is_empty_body` (`scripts/checkpoint.py:361,404`), so an agent that drafts a
headings-only todo file gets a removal it did not ask for and is not told to
expect. Low impact — the outcome is the correct one — but it is a silent
divergence from what the prose promises.

### m3 — `CLAUDE.md:821-824` — style / excess

> "and empty-body removal including that the deletion reaches the manifest. It
> does **not** cover `write-stage.sh` or `bash-post.sh`, **which this sentence
> used to claim**: those are bash and are tested where the two bullets above
> say"

Self-referential commentary about this file's own prior wording, inside a
present-truth document. CLAUDE.md elsewhere narrates *code* history (e.g. "used
to also hold a session-keyed root pointer"), which is a different thing.

The substantive claim is **true** — verified: `grep -c write-stage
tests/hook-test.bats` → 11 (rows at `tests/hook-test.bats:550,572,591,603`);
`grep -c bash-post tests/checkpoint.bats` → 12; `grep -n
"write-stage\|bash-post" tests/test_checkpoint.py` → one hit, and it is a
docstring at line 7, not a test.

### m4 — `CLAUDE.md:815-821` — completeness

The Testing enumeration lists the union's *rejection* rows exhaustively but
none of its *behavioral* rows, which the outline names as additions:
`{"action": "clear"}` against a pre-existing file removing it and recording
`D`; against a never-existed file removing nothing and recording no `D`;
`{"action": "keep"}` leaving the list alone. All three exist —
`tests/test_checkpoint.py:618` (`test_task_clear_removes_pre_existing_file_manifest_records_d`),
`:642` (`test_task_clear_never_existed_writes_nothing_no_d`), `:859`
(`test_todo_keep_leaves_pre_existing_list_alone`) — and `:859` carries the
load-bearing negative (`assert "handoff-todo.md" not in manifest`, guarded by a
positive task line so the absence is a claim about the todo route). They are
the heart of the change and go unclaimed while a dozen schema-error rows are
named individually.

### m5 — `skills/handoff/SKILL.md:142` vs `:194` — consistency

The task-file location rule was deleted ("No location other than
`./.claude/handoff-task.md` — the hook reads this exact path") while the path
was simultaneously added to the template header (`**Task file template**
(`./.claude/handoff-task.md`)`), and the todo equivalent survives at `:194`
("No location other than `./.claude/handoff-todo.md`.").

Defensible as it stands — `handoff-todo.md` *is* agent-editable (FR4), so its
path is load-bearing prose; `handoff-task.md` is not, and `write-guard.sh`
denies a direct Write/Edit to it. But the asymmetry now reads as an oversight
rather than a rule, and the task header names a path the agent can never write
to and no longer supplies in the payload.

### m6 — `docs/changelog/2026-09-07-the-payload-names-its-actions.md:61-63` — clarity

> "that phantom `D` was **one of two routes** to `bash-post.sh`'s `git add`
> failing with `did not match any files` on a path that was never in the index."

The other route is never named here, and the entry is the durable record. It is
recoverable from `scripts/bash-post.sh:33-40`'s comment (a `git reset` since
the last checkpoint, or a file the user wrote by hand, leaves a real removal
targeting an untracked path) but a reader of the changelog alone cannot get it.

---

## Conformance — verified clean

Each of these was checked and found correct; listing them so a missing check is
visibly missing.

**Retired vocabulary fully gone from the producer side.**
`grep -rn "file_path" skills/` → no hits. `grep -rn "abs path to" skills/` → no
hits. `grep -rn "nothing to say" skills/` → no hits. The only `null` survivors
in both skill bodies are on `continue`, where `null` is still valid
(`skills/handoff/SKILL.md:43,97`, `skills/precompact/SKILL.md:29,73`) and the
new "`null` is an error on both" sentences (`:108`, `:80`).

**Producer/validator agreement — both directions.** Validator accepts, per
`scripts/checkpoint.py:265-315`: `task` = string | `{"action":"clear"}`; `todo`
= string | `clear` | `keep` | `edit`+`old_string`+`new_string`. Both skill
bodies name exactly those four actions, spelled identically, in the heredoc
template and the following paragraph. No action is unreachable from the skill
body; no skill-named shape is rejected by the validator. Checked the reverse
direction too: `task` receiving `keep` or `edit` is rejected
(`tests/test_checkpoint.py` ids `task_keep_rejected`, `task_edit_rejected`) and
both skill bodies say "both `todo` only".

**Cross-file union spelling.** Five statements compared word by word — the
outline (`outline.md:19-22`), `CLAUDE.md:536-539`, `docs/design.md:219-224`,
`docs/changelog/2026-09-07-…:36-38`, `skills/handoff/SKILL.md:101-102,105-108`
and `skills/precompact/SKILL.md:76-77,81-83`. All agree: `clear` on both fields;
`keep` and `edit` on `todo` alone; `edit` carries `old_string`/`new_string`.

**`docs/design.md:139-141` — FR5 restated in action terms.** Now
"`{"action": "edit", "old_string": …, "new_string": …}` as well as content
written whole. The task file is authored whole, so it has no edit action and
the schema refuses one." True of `validate_task` (`checkpoint.py:265-283`, no
`edit` arm). FR6 untouched, correctly — it is unaffected.

**`docs/design.md:219-234` — the "harness's own tool-call shape" rationale.**
The outline asked for "a superseding pointer, not a wording edit"; what landed
is a full rewrite *plus* a pointer line at `:234`. This is the better outcome
and conforms to the file's own stated rule (`docs/changelog.md:9-10`: design.md
is "rewritten rather than annotated when a decision is reversed"). The bare
link-on-its-own-line form matches house style —
`docs/design.md:392,473,508,519,907` all do this.

**`docs/design.md:911-921` — rejected-alternatives gained the magic-string
sentinel.** Present, with the argument the outline specified (a typo in a bare
token is indistinguishable from content; `{"action": "emty"}` is a schema error
naming the field) and the note that it is the shape a future session will
re-propose.

**Superseding blockquote scope
(`docs/changelog/2026-07-27-content-null-is-a-no-op.md:3-10`).** Correctly
scoped: "scoped to the remedy, not the diagnosis", and it explicitly preserves
what still stands ("Writing the literal string `null` into the file was a real
defect and had to stop"). The body's diagnosis (lines 12-22) is untouched and
remains true; only the fix described at lines 24-33 is reversed. No over-claim.
The entry body itself was not edited — the never-edit-after-the-fact rule holds.

**New changelog entry structure.** Leads with the motivating incident
(`:3-9` — 2026-09-02, handoff 0.13.1, a frame calling a finished release
unpublished). Carries all five rejected alternatives the outline names, in
order: error on `null` (`:67`), document the `""` workaround (`:75`), make
`null` delete (`:82`), bare magic-string sentinels (`:90`), keep `file_path` as
a cross-project guard (`:99`).

**Changelog entry's factual claims — spot-checked against the code.**
- `:49-51` "`validate_*`/`apply_*` are now wrapped in `if skill in ("handoff",
  "precompact")`" — true, `scripts/checkpoint.py:502-508`.
- `:60-61` "The old code wrote an empty body, unlinked it, and emitted `D`
  unconditionally" — true; `git show e370aed:scripts/checkpoint.py` `apply_task`
  reads `path.write_text(content)` then `if lib.is_empty_body(content):
  path.unlink(); return [f"D …"]`.
- `:106` "The real coverage lives in
  `test_drifted_cwd_writes_injected_root_never_cwd`" — exists,
  `tests/test_checkpoint.py:223`.
- `:3` "handoff 0.13.1" — `.claude-plugin/plugin.json` is at `0.13.1`, tagged
  2026-08-14, so 0.13.1 was the live version on 2026-09-02. Consistent.

**`docs/changelog.md:11` — index line.** Newest-first position correct,
`- [<date> — Title](changelog/<file>.md) — <prose>` matches every one of the
file's other 53 entries. (`CLAUDE.md`'s stated format says "— hook (vX.Y.Z)";
`grep -n "(v[0-9]" docs/changelog.md` returns nothing, so zero of 54 entries
follow it. The convention statement is stale, but it is stale *before* this
change and the new line correctly follows the file rather than the convention.
Not filed as a finding against this range.)

**`CLAUDE.md:802` — "128 tests".** Verified: `pytest --collect-only -q
tests/test_checkpoint.py` → "128 tests collected". (Was 89; 92 test functions,
11 `parametrize` decorators.)

**`CLAUDE.md:815-820` — every named schema row exists.** Checked each against
`tests/test_checkpoint.py`:
- "`null` and an absent key on each of `task`/`todo`" — `:541`,
  `test_task_or_todo_null_or_absent_errors_naming_field`, ids `task_null`,
  `task_absent`, `todo_null`, `todo_absent`, run across both skills.
- "an action outside the field's own vocabulary" — `:480`, ids
  `task_unknown_action`, `todo_unknown_action`, `task_keep_rejected`,
  `task_edit_rejected`.
- "an object with no `action` key" — ids `task_no_action_key`,
  `todo_no_action_key`, reason `"action: required"`.
- "a value that is neither string nor object" — ids
  `task_not_string_or_object`, `todo_not_string_or_object`, value `42`, reason
  `"got number"`.
- "an `edit` missing or mistyping either of its strings" — four ids,
  `todo_edit_missing_old_string` / `_new_string` /
  `_old_string_not_a_string` / `_new_string_not_a_string`.
- The removed claims (`content`+`old_string` together, a partial Edit,
  `file_path` outside `$root/.claude/`) are indeed gone from the suite:
  `grep -n file_path tests/test_checkpoint.py` → no hits.

**`CLAUDE.md:665-671` and `docs/design.md:257-259` — `bash-post.sh` claims.**
Verified against `scripts/bash-post.sh`: the `2>/dev/null` is gone (line 36 in
the old file), the benign `D`-for-a-never-indexed-path case is guarded with
`git ls-files` whose exit status is read (`if ! indexed="$(git -C "$cwd"
ls-files -- "$rel")"; then failed+=("$rel")`), and failures are named on both
channels (`summary`/`agent_ctx` both gain `"; failed to stage: ${failed[*]}"`).
Covered in `tests/checkpoint.bats:335,349,374,398,426`.

**Skill bodies under the ≤2000-word cap.** Body word counts (frontmatter
excluded): `skills/handoff/SKILL.md` 1971 → 1958; `skills/precompact/SKILL.md`
1018 → 1069. Both within budget; the outline's "shorter than what it replaces"
holds for `handoff`, and `precompact` gained 51 words, which is comfortable.

**`skills/handoff/references/design.md`** carries no payload prose and needed no
change — `grep -n "FR5\|FR6\|payload"` → no relevant hits.

---

## Out of scope, noted

`scripts/checkpoint.py:352,371` and `tests/test_checkpoint.py:544` cite `D2`
and `D3` as requirement identifiers. Those are defined only in
`plans/2026-09-04-checkpoint-null-no-task-file/runbook.md:21-22` — a write-time
plan artifact that, per `CLAUDE.md`'s `plans/` rule, is not revised as the code
moves. `FR*` identifiers resolve in `docs/design.md`; `D*` resolve nowhere
durable. Not a prose deliverable, so not filed as a finding, but the same
reference-rot the design.md/changelog convention exists to prevent.

---

## Verification method

Every factual claim in the Conformance section was checked by grep or by
running the command shown; nothing there is asserted from reading alone. Two
things I did **not** do: I did not run `just precommit` (only
`pytest --collect-only` on `tests/test_checkpoint.py`, for the test-count
claim), and I did not exercise either skill body end to end against a live
`handoff-checkpoint` call — M1 is derived from reading the prose against
`scripts/checkpoint.py`'s dispatch, not from observing two agents diverge.
