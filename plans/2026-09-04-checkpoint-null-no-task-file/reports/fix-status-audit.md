# Fix-status audit — `reports/deliverable-review.md`

**Date:** 2026-09-13
**Subject:** every finding in
`plans/2026-09-04-checkpoint-null-no-task-file/reports/deliverable-review.md`
(1 Critical, 4 Major, 18 Minor, 2 process), cross-checked against its two
Layer-1 inputs.
**Method:** each verdict is derived from the artifact as it stands in the
working tree today. (The tree carried an uncommitted prose change in `CLAUDE.md`
and one docstring change in `scripts/checkpoint.py` when this audit began; both
were amended into `ab8f5b2` by another session while it ran. The bytes are
unchanged either way — `git diff HEAD` is now empty — and neither hunk moves a
verdict.) Every line number below was re-derived by grep or by
reading — none is carried over from the review. Claims made by later plans,
reports, changelog entries, commit messages or the live todo list were not
treated as evidence of a fix; where they are cited it is for **deferral**
decisions only, and it is said so.

**Classification rule used.** `deferred` means a *frozen* plan document ruled
the finding out of scope. `open` means outstanding with no such document, even
where the live `.claude/handoff-todo.md` schedules the work — a scratch list is
an intention, not a decision.

**Empirical work done for this audit:** six payload probes against a throwaway
`HANDOFF_ROOT`, one `bash-post.sh` run against a non-repo root, and two
mutation checks (`todo`'s `clear` branch; the apply ordering) run on a copy of
`scripts/` + `tests/` under `$TMPDIR`. The repository tree was not modified.
Baseline in that copy: **140 passed**.

---

## Verdicts

| id | title | severity | verdict | strongest evidence |
|---|---|---|---|---|
| C1 | a failed `todo` edit destroys the task frame, unrecorded | Critical | fixed | `scripts/checkpoint.py:578-587` plans both halves before applying; restoring the old ordering reds 4 rows and nothing else |
| M1 | `todo: {"action": "clear"}` has zero coverage | Major | fixed | `tests/test_checkpoint.py:723,753` + `todo_clear()` at `:130`; neutering the branch reds `test_todo_clear_removes_pre_existing_file_manifest_records_d` alone |
| M2 | neither skill body says which action a no-todo boundary sends | Major | fixed | `skills/handoff/SKILL.md:107-110`, `skills/precompact/SKILL.md:82-85`: "`keep` is the default and `clear` is a deliberate stand-down" |
| M3 | action objects and the payload ignore unknown keys | Major | **open** (residual) | action objects fixed (`checkpoint.py:278-296`, probe errs); top-level still silent — `{…,"tasks":"oops"}` → rc 0 |
| M4 | `task.action: required` names no vocabulary | Major | fixed | `checkpoint.py:309`, `:336-339`; probe prints `required, a content string or {"action": "clear"}` |
| m1 | `{"action": null}` conflated with an absent key | Minor | fixed | `checkpoint.py:308-314`; probe → `task.action: must be "clear", got null` |
| m2 | non-string `action` renders a Python repr | Minor | fixed | `_got()` at `checkpoint.py:265-275`; probe → `got boolean` |
| m3 | `apply_todo` writes an empty body before unlinking | Minor | fixed | `_plan_file` decides emptiness from the body in hand (`checkpoint.py:412-428`); `edited_body` returns rather than writes (`:396-409`) |
| m4 | a whitespace-only body is written as content | Minor | deferred | `outline.md:39` puts `is_empty_body` **OUT**; `_checkpoint_lib.py:30-33` unchanged, probe writes a 3-byte file |
| m5 | a non-git root reports a failure at every checkpoint | Minor | deferred | 2026-09-08 `outline.md` Scope names m5 as not in scope; reproduced verbatim against `bash-post.sh:53-68` |
| m6 | the "git's stderr reaches the user" comment is unverified | Minor | **open** | comment still stands at `bash-post.sh:75-79`; named by no frozen document |
| m7 | the manifest is consumed even when every path failed | Minor | deferred | 2026-09-08 `outline.md` names m7; `bash-post.sh:70` still unconditional, reproduced |
| m8 | `…_file_missing_errors` names no field | Minor | fixed | `tests/test_checkpoint.py:1035` asserts `"todo.old_string" in result.stderr` |
| m9 | the both-written row does not bound the manifest | Minor | fixed | `tests/test_checkpoint.py:1191` is now exact list equality |
| m10 | bats uses jq `test()` (regex) on dotted paths | Minor | deferred | "the cosmetic set" (2026-09-08 `outline.md`); still `test(…)` at `checkpoint.bats:376,378,400,402,428,430` |
| m11 | `handoff_payload()` is an uncommented cross-file coupling | Minor | fixed | pointers now on both sides: `checkpoint.bats:211-212` and `tests/test_checkpoint.py:117-119` |
| m12 | `D2`/`D3` cited in shipped code, resolving nowhere durable | Minor | deferred (partial) | 2026-09-08 `outline.md` names m12; two of three citations gone with the rewrite, `tests/test_checkpoint.py:603` remains, `D2` still only in `runbook.md:21` |
| m13 | the skill bodies omit the `edit` action's preconditions | Minor | fixed | `skills/handoff/SKILL.md:111-112`, `skills/precompact/SKILL.md:86-88` |
| m14 | FR6 is stated in neither skill body | Minor | deferred | 2026-09-08 `outline.md` names m14; no removal-by-empty-body prose in either body |
| m15 | `CLAUDE.md` narrates its own prior wording | Minor | deferred | "the cosmetic set"; the sentence survives at `CLAUDE.md:840-842` |
| m16 | `CLAUDE.md` names no behavioral rows | Minor | deferred (partial) | "the cosmetic set"; the `clear` pair and the edit-to-empty route are now named (`CLAUDE.md:834-839`), `keep` still is not |
| m17 | the task-file location rule is asymmetric | Minor | deferred | "the cosmetic set"; `skills/handoff/SKILL.md:198` keeps the todo rule, the task rule is still absent beside the header at `:146` |
| m18 | the changelog names one of two routes | Minor | deferred | "the cosmetic set"; `docs/changelog/2026-09-07-the-payload-names-its-actions.md:62` unchanged, as the never-edit rule requires |
| P1 | `phase-1-corrector.md`'s mutation evidence does not reconstruct | Process | **open** | `reports/phase-1-corrector.md:168-173` still carries the claim, with no correction block |
| P2 | no stated convention for correcting a write-time report | Process | **open** | `CLAUDE.md:728-731` (`plans/` bullet) states the never-revise rule and no correction form |

No finding was **not located**. Every subject named by the review resolved to a
current artifact.

Findings appear in both Layer-1 reports and the consolidation with a clean
mapping — nothing was dropped. Code-layer Major 1/2/3 are M1/M4/C1; code
Minor 1-9 are m2, M3, m3, m4, m6, m7, m9, m10, m8; prose Major 1 is M2; prose
m1-m6 are m13, m14, m15, m16, m17, m18; the prose report's "Out of scope,
noted" is m12. Three findings exist **only** in the consolidation — m1, m5 and
m11 — and are audited above like the rest. The code report's "Process note for
the lead" (serialise concurrent mutation work) was never filed as a finding and
is not audited.

---

## What remains, finding by finding

### M3 — top-level unknown keys (open, residual)

The severity-bearing half is closed. `_reject_unknown_keys`
(`scripts/checkpoint.py:278-296`) is called on every action object —
`task`'s `clear` (`:312`), `todo`'s `clear`/`keep` (`:342`) and `todo`'s `edit`
(`:345`) — so the route the review called out (an agent told `must be "clear",
got "write"` that corrects only the action and leaves `content` behind) now
errs:

```
task: {"action":"clear","content":"IMPORTANT UNSAVED"}
→ handoff-checkpoint: task: unknown key "content", {"action": "clear"} takes no other key   rc=2
→ task file still present
```

Four table rows pin it (`tests/test_checkpoint.py:460-479`, ids at `:513-516`:
`task_clear_with_unknown_key`, `todo_keep_with_unknown_key`,
`todo_clear_with_edit_key`, `todo_edit_with_unknown_key`), each asserting the
message names the field.

What is left is the top level. `read_payload` (`:91-100`) parses and returns,
and nothing compares the key set:

```
{… ,"tasks":"oops"}   → rc 0, key ignored
```

Impact is much lower than the half that was fixed: a *misspelled* `task` or
`todo` key still fails loudly, because both are required by key presence — only
a genuinely superfluous key is swallowed. A fix would touch `read_payload` (or
a new check in `main` after `validate_skill`, since the legal key set is
skill-dependent — the four forbidden-field validators at `:157-172` already
encode part of it), plus one table row per skill.

No document defers this. `docs/design.md:229-236` records the action-object
rule that landed and says nothing about the top level; the pass-2 list in
`.claude/handoff-todo.md` does not carry it either. It is the one finding that
appears to have been closed in the ledger while half of it stands.

### m6 — the unverified stderr comment (open)

`scripts/bash-post.sh:75-79` still asserts "git's stderr now reaches the user".
Nothing in the tree demonstrates that; `tests/checkpoint.bats:405`'s
`grep -q 'index.lock'` proves only that git's message reaches the process's
stderr. A fix is a comment edit (downgrade to what the bats rows pin: the named
path on `summary` and `agent_ctx`), plus — if the answer turns out to be "not
outside debug mode" — it shrinks m5 to transcript noise.

This one is named by no frozen document: the 2026-09-08 outline's deferral list
is "m5, m7, m12, m14, and the cosmetic set". It is tracked on the live
`.claude/handoff-todo.md`, inside the same pass-2 item as m5 ("Settle m6
first"), which is why it is classified open rather than deferred.

### P1 — the unreproducible mutation (open)

`plans/2026-09-04-checkpoint-null-no-task-file/reports/phase-1-corrector.md:168-173`
is unchanged and still records that "mutating `validate_root` to fall back to
`Path.cwd()`" reds `test_drifted_cwd_writes_injected_root_never_cwd`. No
`> **Corrected at review, <date>.**` block was added. The form exists elsewhere
in the same directory (`reports/item-1-2-red.md:98`, `:130`), so a fix is one
blockquote — but it is gated on P2, which decides whether that form is the
convention.

### P2 — no correction convention for `plans/` (open)

`CLAUDE.md:728-731` reads exactly as the review quoted it: `plans/` are
write-time records "not revised as the code moves past them", with no
correction form stated, while the `docs/changelog/` bullet states its
`> **Superseded <date>**` form. A fix is one clause on that bullet.

### The deferred set — what is actually still there

- **m4** — `_checkpoint_lib.py:30-33` tests `line == ""`, so `"task": "   "`
  writes a 3-byte file with a `W` line (probed). Ruled out at the start:
  `outline.md:39` — "**OUT:** `write-stage.sh`, `is_empty_body`, …".
- **m5** — reproduced against the current script with a non-repo root:
  `staged 0, deleted 0; failed to stage: .claude/handoff-task.md` on both
  channels, plus git's raw `fatal: not a git repository` on stderr. No
  whole-run `git rev-parse --git-dir` guard exists (`bash-post.sh:53-68`).
- **m7** — in that same run the manifest was consumed
  (`$TMPDIR/nonrepo/.claude/` holds only `handoff-task.md` afterwards), the
  agent channel named the path with no remedy, and the "Leave them staged"
  clause was correctly suppressed (`bash-post.sh:70`, `:86-100`).
- **m10** — six `jq … test("failed to stage: .claude/…")` assertions remain.
- **m12** — the rewrite took `checkpoint.py`'s two citations with it; the
  surviving one is a docstring, `tests/test_checkpoint.py:603` ("D2: task/todo
  are each required by key presence"). `D2` is still defined only at
  `plans/2026-09-04-checkpoint-null-no-task-file/runbook.md:21`; `docs/design.md`
  has no `D<n>` identifiers at all.
- **m14** — neither body mentions that a drafted body empty under
  `is_empty_body` removes the file. Both bodies name `clear` as the removal
  route (`skills/handoff/SKILL.md:104-113`,
  `skills/precompact/SKILL.md:80-89`) and stop there.
- **m15** — `CLAUDE.md:840-842`: "It does **not** cover `write-stage.sh` or
  `bash-post.sh`, which this sentence used to claim".
- **m16** — narrowed by the M1 fix: `CLAUDE.md:834-839` now claims the `clear`
  pair "covered on both `task` and `todo`", the todo half's mutation check, and
  the edit-to-empty route. `{"action": "keep"}` leaving the list alone
  (`tests/test_checkpoint.py:1074`) is the one behavioral row still unclaimed.
- **m17** — `skills/handoff/SKILL.md:198` still reads "No location other than
  `./.claude/handoff-todo.md`."; the task-file equivalent is still absent, with
  the path appearing only in the template header at `:146`.
- **m18** — `docs/changelog/2026-09-07-…:62` is unchanged and must stay so
  (entries are never edited after the fact). The two routes *are* now named in
  `scripts/bash-post.sh:37-45`; closing this durably means a line in
  `docs/design.md` or a later entry, not an edit here.

The deferral documents, quoted:

> **OUT:** `write-stage.sh`, `is_empty_body`, the sentinel composer/parser
> pair, the `autoname`/`restart` payloads
> — `plans/2026-09-04-checkpoint-null-no-task-file/outline.md:39` (m4)

> The remaining pass-2 minors (m5, m7, m12, m14, and the cosmetic set) are not
> in scope here.
> — `plans/2026-09-08-apply-before-mutate/outline.md`, §Scope

"The cosmetic set" is not enumerated in that frozen document. The enumeration
used above — m10, m15, m16, m17, m18 — comes from the live
`.claude/handoff-todo.md` ("Pass 2, cosmetic — one editing pass: m10 …, m15 …,
m16 …, m17 …, m18 …"), which also records "m3 was subsumed by C1's restructure"
and "m4 stays explicitly out of scope". That list is agent-editable and is
cited here as the enumeration only; every state claim above was checked against
the file it names.

### Two fixes worth their own evidence

**C1.** `main` now resolves both halves before touching disk
(`scripts/checkpoint.py:578-587`); `edited_body` (`:396-409`) returns the
replacement instead of writing it, and `plan_todo`'s file-absent `err()`
(`:456-460`) fires during resolution. Four rows pin it —
`tests/test_checkpoint.py:961`, `:989`, `:1017` (each asserting the task file
survives *with its original bytes* and that no manifest was written) and
`:1042`, the opposite sign, where a task half carrying content must not be
created. Mutation-checked for this audit: moving `apply_plan(task_plan)` back
above `plan_todo` reds exactly those four and nothing else (`4 failed, 136
passed`); restored, `140 passed`.

Note that the landed fix is not the review's "cheapest remedy". The review
proposed hoisting the two `edit` preconditions; the successor outline rejected
that explicitly — it "removes today's two triggers and leaves the ordering
itself unchanged: the next apply-time failure anyone adds reopens the defect,
silently" — and took the structural route. The guarantee's stated limit is
unchanged and honest: an `OSError` mid-apply still strands a half-applied
wrap-up, which both the outline and `apply_plan`'s docstring say outright.

**M1.** `todo_clear()` exists at `tests/test_checkpoint.py:130` beside its three
siblings, and the mirrored pair is at `:723` (pre-existing file removed, `D`
recorded, with a live `W` task line so the manifest is not vacuous) and `:753`
(never existed, no `D`, same live task line). Mutation-checked: replacing
`plan_todo`'s `clear` arm with the empty plan reds
`test_todo_clear_removes_pre_existing_file_manifest_records_d` alone (`1 failed,
139 passed`) — the branch the review proved dead is now live to the suite.

### Outside the numbered findings

The review's Gap Analysis closes with "Version bump for delivery — **Open** —
my human partner's call". Still open: `.claude-plugin/plugin.json:3` is
`0.13.1`, the tagged-union work and the apply-before-mutate restructure are both
unreleased, and `.claude/handoff-todo.md` records the question as "raised in four
sessions now and not answered".

---

## Counts

| verdict | count | ids |
|---|---|---|
| fixed | 11 | C1, M1, M2, M4, m1, m2, m3, m8, m9, m11, m13 |
| deferred | 10 | m4, m5, m7, m10, m12, m14, m15, m16, m17, m18 |
| open | 4 | M3 (residual), m6, P1, P2 |
| not located | 0 | — |

Of the five findings the review itself called the cluster — C1, M1, M2 plus M3
and M4 — four are fully closed and one (M3) is closed on the half that carried
its severity. Both process findings are untouched.

---

## What the review missed or got wrong

Short, and only where it changes how a reader should use it.

- **m11 contradicts its own Layer-1 input, and the consolidation did not say
  so.** `deliverable-review-code.md`'s conformance section examined the same
  fixture and concluded the opposite — "No duplication of semantics and no
  contradiction; it is the one payload that suite needs and it is constructed
  once." The consolidation filed it as a Minor anyway without noting the
  disagreement. Harmless here (the remedy was a comment, and the comment
  landed), but a reader reconciling the two layers should know the
  consolidation silently overrode one.

- **m12's premise is narrower than its statement.** It reads as "`D2`/`D3` are
  cited in shipped code"; two of the three citations were in `checkpoint.py`
  functions the C1 restructure deleted outright, so most of the finding was
  retired by an unrelated change rather than by anyone acting on it. Only a
  test docstring is left. Worth knowing before someone budgets a pass for it.

- **m4 has an adjacent case it does not name.** `is_empty_body` skips any line
  beginning with `#`, not only markdown headings, so a body such as
  `#!/bin/sh\n` is "empty" and removes the file — the same rule and the same
  out-of-scope status as the whitespace case, but a second route to it. Noting
  it so the eventual `is_empty_body` pass is scoped to both.

- **M4's supporting anecdote has expired.** The finding argued from the fact
  that "the handoff task frame for this very job carries a warning that a
  post-`/clear` session may compose the retired shape". That frame
  (`.claude/handoff-task.md`) no longer carries any such warning. The finding
  itself was right and is fixed; only its liveness evidence is stale — which is
  the rotting-state class the review's own P1 is about.

Nothing else in the review failed to reconstruct. Its four mutation claims, the
C1 reproduction and the counts all held up where I re-ran them.
