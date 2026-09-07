# TDD audit — `plans/2026-09-04-checkpoint-null-no-task-file`

Scope: the run's 18 commits, `c2dc443..HEAD` (`2e5c38f` … `ee4f618`), and the
21 reports under `reports/`. Read-only: nothing in the repository was edited,
and every mutation below was applied to a throwaway copy of `scripts/`,
`tests/`, `bin/` under `/tmp/claude-1000/`, never to the working tree. The
copies are deleted; `git status --short` is empty.

**Verdict: the run's TDD discipline holds.** Every claim I could check
independently reproduced, including the two characterization matrices whose
numbers had already been corrected once. Six process findings, none of them a
hole in the evidence; five product observations handed to `/deliverable-review`.

## What I verified, and how

Not by reading the reports. Each row below is a command I ran.

| claim | check | result |
|---|---|---|
| suite green at every commit | `git archive <rev>` into a scratch tree, `pytest tests/test_checkpoint.py` at each of the 12 code/test commits | green at all 12, with **exactly** the counts the reports claim: 107 (`e9f985f`), 115 (`695a086`), 122 (`57bc5be`), 124 (`2ee1fbf`, `1845f75`), 126 (`87ce9c5`), 128 (`1e634fe` onwards) |
| bats green, and the row counts | same, `bats tests/hook-test.bats tests/checkpoint.bats` | 159 at `1e634fe`, 162 at `5cd0b82`, 164 at `fc4a661` and `ee4f618` — matching every report |
| Item 1.2 M1 (gate narrowed to `handoff`) reds 6 | applied at HEAD in the copy | **6**, exactly the named set |
| Item 1.2 M2 (`W` lines dropped) reds 13, not the 12 the review measured | same | **13**, the extra being `test_task_clear_removes_pre_existing_file_manifest_records_d` — the Phase 1 corrector's amendment is right |
| the Phase 1 corrector's `edit`-key type check is load-bearing | deleted the type check | reds `todo_edit_{old,new}_string_not_a_string` **alone** |
| slice 3's finding-1 fix (message-specific `reason`) survives a *weakened* guard | replaced the presence guard with `todo.setdefault(key, "")` | reds `todo_edit_missing_{old,new}_string` **on the `reason` assertion**, not the exit code — the fix is what makes those rows evidence |
| the `keep` row's manifest-absence claim is pinned | made `apply_todo`'s `keep` branch emit a phantom `W` line | reds `test_todo_keep_leaves_pre_existing_list_alone` on `assert "handoff-todo.md" not in manifest` |
| `test_drifted_cwd_writes_injected_root_never_cwd` stays green **and** discriminating | green at HEAD; mutated root resolution to `Path.cwd()` | reds, together with `test_handoff_root_names_non_directory_refuses` — see finding 1 for the wording caveat |
| Item 2.1's load-bearing bats row was genuinely red | ran `5cd0b82`'s `checkpoint.bats` row against `1e634fe`'s `bash-post.sh` | `not ok … a path that cannot be staged`, failing on its own `jq -e` assertion |
| the Phase 2 review's two added rows discriminate | row 163 against `5cd0b82`'s unfixed guard; row 164 against a period regression at HEAD | 163 red against the pre-fix guard; 164 red **alone** under the period mutation |
| test integrity | `def test_` name lists diffed `c2dc443` → HEAD; removed-`assert` lines from the same diff | exactly the authorised deletions/restatements/renames, nothing else; no assertion weakened |
| report hashes | `git log -1` on every hash named in a report | all resolve, and each carries the files its report claims |

## 1. Per-slice RED evidence

**Slices 1 and 4 — genuine, with one caveat on slice 1.**

Slice 4 is textbook: its two never-existed rows fail on their own manifest
assertion, the pasted output names the phantom directly
(`assert 'handoff-task.md' not in 'D .claude/handoff-task.md\n'`), and its two
paired rows pass with the report drawing no inference from that. Its review
went further and demonstrated the pairing is carried *inside* the pair (planned
GREEN + `return []` reds exactly the two pre-existing halves, and nothing else
in 124 rows).

Slice 1's five rows all fail on `assert result.returncode == 0` — a real
assertion, not a missing symbol, and the review re-ran it rather than taking the
report's word. The caveat is that four of the five red on the **task** field's
`task.file_path: required`, including the two rows whose subject is `todo`, and
they red alongside 47 unrelated rows. That is inherent to Phase 0's factory
design, which the runbook chose deliberately and warned about ("the red is
genuine and needs no stub"), so it is not a violation. But as evidence it says
"the payload shape as a whole is rejected", not "this row's contract is
unimplemented". What closes the gap is downstream, not in the RED report: the
slice 1 code review's twelve-case probe, its `clear`-pair mutation, and slice
4's and Item 1.2's mutations over the same rows. Worth naming so a future run
does not read slice 1's RED as the model.

**Slices 2, 3 and Item 1.2 — the substitute carries the weight.** I checked the
two properties that matter and both hold:

- *Every row is redded by some single mutation.* Slice 2: A/B/C/D/E cover all
  eight rows (A the `null` pair, B the `absent` pair, D the `precompact` halves,
  E the `absent` rows' reason). Slice 3: M1–M10 red nine rows one apiece, M3
  reds three together, and the review added **M12** precisely because
  `task_unknown_action` was otherwise reachable only through M3's group — that
  is the audit question asked and answered before I could ask it. The Phase 1
  corrector's two type rows are covered by its own mutation, which I reproduced.
  Item 1.2: M1 and M2 red the four target rows, and the review's M3/M4 pin each
  row's *original* claim so the amendment cannot have replaced one claim with
  another.
- *No mutation reds everything.* The widest is M2 at 13 of 128. Slice 2's
  mutation C does red all eight rows of its own table, which would be the
  failure shape — except the review checked the **failing assertion line** for
  every cell (C at 539, the file-not-created assertion; E at 537; A/B at 534),
  so C is pinning one claim across the table rather than blanket-failing it.
  That is the right level of rigour.

## 2. Were the matrices reproduced, or accepted?

Reproduced, by a method each review states and that differs from the
dispatch's: a scripted patcher asserting `count(old) == 1` before replacing (so
a mutation that fails to apply is an error, not a silent green), one mutation
per cycle off a clean baseline, and the restore asserted **in the shell** after
every cycle. Slice 3's review ran 26 cycles, Item 1.2's four, and each added
mutations the dispatch did not have.

Three measurement disagreements, all corrected in place:

1. **`item-1-2-red.md`'s disjointness claim.** The dispatch asserted "M1's red
   set is exactly {…2 rows}; M2's is exactly {…2 rows}" — a full-suite property
   no run in that dispatch measured, since every pasted run was `-k`-filtered.
   The review measured it: M1 reds 6, M2 reds 12. **Honest correction**: the
   original sentence is preserved verbatim inside a dated
   `> **Corrected at review**` block, the measured sets are listed, the reason
   the excess is correct coverage is given, and the paragraph is rewritten to
   claim only what is true (disjointness of *what each mutation edits*).
2. **`item-1-2-red.md`'s arithmetic** ("122 existing + 4 new"). Both halves
   wrong; corrected to 124 + 2 = 126, with `diff` of the `def test_` name lists
   proving no row was lost. I re-derived 124 at `1845f75` and 126 at `87ce9c5`
   independently — both correct.
3. **The Phase 1 corrector against the Item 1.2 review**: M2 reds 13 at the tree
   that landed, not the 12 measured before the pair-symmetry fix went into the
   same commit. I measured 13 at HEAD. The amendment is in both files, dated,
   with the reason.

The one convention tension: these are edits to **write-time dispatch records**,
which this repo's convention says are not revised after the fact. The dated,
quote-preserving block form makes the edit auditable rather than silent, so I
judge it the right call — but it is worth stating as the rule (`a correction to
a write-time record is a dated block that quotes what it corrects`) rather than
leaving each reviewer to invent it.

## 3. Commit discipline

Clean. One commit per slice carrying tests and implementation together where
there is an implementation (`e9f985f`, `2ee1fbf`); tests alone for the three
characterization dispatches (`695a086`, `57bc5be`, `87ce9c5`), which is correct
since nothing was left to implement. `Item N.M/k` appears in all four slice
subjects. Every review fix is a separate orchestrator commit (`1845f75`,
`1e634fe`, `fc4a661`, `2abc6e5`, `ee4f618`), and every report's named hash
resolves and carries the files it claims. Suite green at all 12, verified by
running each, with the exact counts the reports state.

Two notes, neither a violation:

- `e9f985f` carries `tests/checkpoint.bats` outside Item 1.1's stated scope. It
  was declared as a departure in the GREEN report, ruled faithful and
  behaviour-preserving by the code review (the one affected row asserts shim
  forwarding, not payload semantics), and it was unavoidable — precommit is a
  commit gate. Correctly handled.
- `2ee1fbf` has a subject and no body, the only commit in the run without a
  reasoned message. Its report carries the reasoning.

## 4. Test integrity

No test was weakened, deleted without authorisation, or rewritten to fit an
implementation. The name-list diff `c2dc443` → HEAD removes exactly 14 rows:
the **8 authorised deletions** (four `{"content": null}` no-ops, two
`file_path`-outside-root rows, `test_todo_content_and_old_string_together_errors`,
`test_drifted_cwd_task_path_under_cwd_rejected`), the **3 authorised
restatements** into slice 3's table, the **2 slice-4 splits**, and the **1
slice-1 rename**. Nothing else. Every removed `assert` line in the diff belongs
to a deleted row or to a strengthening — three substring assertions became exact
equality (`"real content" in …` → `== content`, `"an item" in …`,
`"untouched" in …` → `== before`).

The three rows the runbook froze
(`test_todo_edit_old_string_absent_errors`, `…_ambiguous_errors`,
`…_requested_file_missing_errors`) differ from their base version by exactly one
line each: the dropped `repo` argument in `todo_edit(...)`. Same for
`test_drifted_cwd_writes_injected_root_never_cwd`, which is green at HEAD and
still discriminating — mutating the root resolution to use the cwd reds it.

One row deserves a note because it is the opposite of test-weakening:
`test_task_write_only_headings_removed_manifest_records_d` **encoded the
defect** — it asserted a `D` for a file it never created. Slice 4's review
caught that the split was therefore a correction rather than an addition, and
said so. That is the single sharpest observation in the run's review record.

## 5. Residual routing

Sound, not deferral. Three residuals, all closed inside Phase 1:

- *precompact validates but is never shown to apply* (slice 2's review) and
  *two slice 1 rows assert an absence over an empty manifest* (slice 4's
  review) → routed to a new Item 1.2, recorded in the runbook (`09c1adb`) with
  its own dispatch and review, closed at `87ce9c5`, two commits later. The
  stated ground — amending a committed slice's rows from a later slice's
  dispatch puts the edit in the wrong commit — is a real constraint, and the
  cost of honouring it was one extra item in the same phase. Both residuals are
  demonstrably closed: M1 and M2 red the amended rows and left them green
  before.
- *pair symmetry* (Item 1.2's review) → the orchestrator overrode the review's
  routing and fixed it inside `87ce9c5`. **Correct, and consistent with the very
  principle the other two rest on**: the edit belongs in the commit that caused
  the asymmetry, and Item 1.2's own amendment is what caused it. Verified at
  HEAD — both halves of the `clear` pair now carry the same
  `todo_content(...)`, so the pair differs only in prior existence again, and
  the pre-existing half reds under M2 (which is why M2's count moved to 13).

## 6. The orchestrator's own conduct

- **The override** (above) is the one call I would have made too, and it was
  disclosed in the commit message with the reason.
- **The two Phase 4 findings the review routed out of its own scope** —
  `checkpoint.py`'s module docstring still saying "Write-or-Edit forms", and
  `CLAUDE.md`'s Testing section crediting `test_checkpoint.py` with covering two
  bash scripts — were fixed in `ee4f618`. Both landed (docstring now reads
  "tagged union — content, or an object naming an action"). Taking them on was
  right: the first is a Phase 1 residual inside the run's scope, and the second
  is a self-contradiction in the agent-instructions file, which the commit
  message states plainly rather than smuggling.
- **The mutation-restore hazard episode** is the one gap. The artifacts I can
  read contain **no record of it**. What they do contain are two neighbouring
  incidents: slice 2's review discloses a `cp` restore that silently no-op'd and
  stacked mutation B on A (caught by the `cp: cannot stat` line, redone from a
  `git checkout` baseline), and the Phase 1 corrector discloses `$TMPDIR` being
  empty, `sha256sum > "$TMPDIR/base.sha"` failing on `/base.sha`, the `&&` chain
  short-circuiting, and "no mutation ran … Redone under `/tmp/claude/p1review/`".
  Neither mentions a `git checkout --` discarding uncommitted implementation
  work. So the disclosure the lead describes was made **in-session only** and
  left no durable artifact — a reader of this plan directory cannot learn that
  it happened.

  On whether any of its evidence was relied on afterwards: **no.** Every claim
  that episode could have contaminated is a mutation result, and I reproduced
  the load-bearing ones independently at HEAD — M1 = 6, M2 = 13, the type-check
  mutation, the weakened-guard mutation — plus the whole suite at every commit.
  Nothing in the landed tree rests on a measurement from a corrupted cycle.

  One residual the episode leaves behind, and it is live: the runbook's Item 1.2
  prescribes "**Restore with `git checkout -- scripts/checkpoint.py`, never a
  `cp` from a saved copy**". That advice is safe only when the tree holds no
  uncommitted work — which is precisely false in a review dispatch that has
  already applied its own fixes, and is how implementation work gets discarded.
  Both the slice 4 code review and the Phase 1 corrector independently worked
  out the safe form on their own ("*never `git checkout --`, which would have
  discarded my own fixes along with the mutation*" — exact-string reversal, with
  the restore asserted by `sha256sum -c` against a hash taken before the first
  mutation). The protocol should say **which restore belongs to which situation**
  — `git checkout --` only from a clean tree, exact-string reversal plus a hash
  check when the tree carries uncommitted work — rather than banning `cp` and
  leaving the rest implicit.

## Process findings

1. **A mutation description that does not reconstruct.** The Phase 1 corrector
   records "mutating `validate_root` to fall back to `Path.cwd()` reds
   [`test_drifted_cwd_writes_injected_root_never_cwd`]". Implemented literally
   (`os.environ.get("HANDOFF_ROOT", "") or str(Path.cwd())`) it reds only
   `test_handoff_root_unset_refuses` — the drift row sets `HANDOFF_ROOT`, so a
   *fallback* never fires. The mutation that reds it is "root **is** cwd,
   unconditionally", which also reds the companion row the report names, so the
   finding is sound and the wording is what is wrong. The bar to hold it to is
   slice 3's review's own: "every mutation description was reconstructable
   unambiguously from its one-line rule". This one is not.
2. **Slice 1's RED is coarse** — five rows redding on one whole-schema
   rejection, two of them on the other field's error, amid 47 unrelated reds.
   Design consequence of Phase 0, compensated downstream, but not a model.
3. **A behaviour change landed in a review-fix commit.** The Phase 1 corrector's
   `edit`-key typing is a genuine schema fix with two new rows, committed in
   `1e634fe` rather than as a slice. A natural red was available (the row fails
   with exit 1 and a `TypeError` against the unfixed code, and the report shows
   exactly that from a CLI probe), but no failing-test red was recorded; the
   mutation stands in. I reproduced the mutation. Sequencing note, not a hole.
4. **The evidence standard is uneven between `tdd` and `inline` items.** Items
   2.1, 3.1 and 4.1 produced no dispatch report; for Item 2.1 the only durable
   record that its load-bearing row was red first is a clause in the commit
   message. It held when I checked it against the pre-change script — but it
   held because the orchestrator happened to write it down.
5. **Corrections to write-time records need a stated form.** Three were made in
   dated quote-preserving blocks, which is right; nothing says so anywhere.
6. **The task frame is stale.** `.claude/handoff-task.md` at HEAD still reads
   "Slices 1 and 2 are done and reviewed; slice 3 is next" after all five phases
   landed. Hygiene, not deliverable.

## Product observations — handed to `/deliverable-review`, not developed here

- An action object's **extra keys are silently ignored**:
  `{"action": "clear", "content": "…"}` exits 0 and writes nothing. Recorded by
  the Phase 1 corrector as a question routed to Phase 3/4; neither phase
  answered it, so the payload still has one shape that quietly does something
  other than what it says.
- `{"action": null}` reports `<field>.action: required`, conflating an absent
  key with an explicit null one — the exact conflation this job's whole premise
  argues against, left deliberately by the slice 1 code review.
- `test_todo_edit_requested_file_missing_errors` asserts only
  `"does not exist" in stderr`, naming no field. Pre-existing and frozen by the
  runbook; the `todo.old_string` namespace now carries four distinct messages,
  which is what makes it worth revisiting.
- **New user-visible behaviour from Phase 2**: a handoff root that is not a git
  repository now reports `failed to stage: .claude/handoff-task.md` on both
  channels at every checkpoint, plus git's own fatal on stderr, where it
  previously read `staged 0`. Named as an accepted consequence by the Phase 2
  review; Phase 4 documented it. The behaviour itself deserves a deliverable
  look.
- `tests/checkpoint.bats`'s `handoff_payload()` fixture was repointed to
  `{action:"clear"}/{action:"keep"}` inside `e9f985f` — reviewed and correct,
  but it means one bats row's payload is now the only cross-file coupling to the
  union's spelling.
