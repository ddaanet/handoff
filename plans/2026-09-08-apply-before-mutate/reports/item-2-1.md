# Item 2.1 — the docs the reordering invalidates

Four files, one pass, amended onto item 1.1's slice commit. Date taken as
**2026-09-13**, not the runbook's assumed 2026-09-10, per the runbook's own
slip rule.

## The four files

### `docs/changelog/2026-09-13-nothing-is-written-until-both-halves-resolve.md` (new, 79 lines)

Written against `scripts/checkpoint.py` as item 1.1 left it, read in full
before drafting — not against the runbook's paragraph describing it.

Leads with the motivating fact: `main()` applied the task half then the todo
half, so a malformed todo half removed `handoff-task.md`, wrote no manifest,
staged nothing, and reported an error naming only `todo.old_string`, with
nothing on either channel connecting the two. Names
`task: {"action": "clear"}` beside a `todo` `edit` as the ordinary boundary
where the task finished and the list has leftovers, and the likeliest trigger
there as the one the schema cannot catch — an `old_string` composed from what
the agent remembers of a file it edited earlier in the session.

Then §The change: `FilePlan`, `plan_task`/`plan_todo`, `edited_body`,
`_plan_file` as the sole producer of the three shapes, `apply_plan` with no
failure branch, `main()` concatenating the manifest lines — plus the two
stated exclusions (`OSError`; `compose_sentinel`'s read-back, with
`write_manifest` already run), scoped exactly as the runbook's scope note
scopes them.

§Rejected carries both weighed remedies: hoisting the two `edit` checks
(removes today's triggers, leaves the ordering unchanged so the next
apply-time failure reopens the defect silently, and counts `old_string`'s
occurrences in a second place that can drift) and writing the manifest for
whatever was applied (records the loss but leaves recovery to a user who must
notice the deletion first, and a frame that never reached a commit is gone
outright).

§What falls out closes on the emptiness test reading a value on both halves,
an empty body never written first on either, and the `edit`-to-empty row that
pins the behaviour whose rationale the change deletes.

No `> **Superseded**` header written anywhere; `2026-09-07-…` untouched.

### `docs/changelog.md` — one index line

Added above the 2026-09-07 row, newest first, one physical line, no version.
Shape follows both neighbours: defect first (the ordering, the removed frame,
the error naming only `todo.old_string`), then the two rejected remedies, then
the plan/apply structure and the emptiness test falling out of it.

### `docs/design.md` — §One channel, one writer

Three changes, all inside the write-semantics paragraph:

- `apply_task`/`apply_todo` → `plan_task`/`plan_todo` in the `file_path`
  sentence.
- One added sentence stating the guarantee positively and bounded to the two
  halves: "The wrap-up is applied whole or not at all: both halves resolve to
  a plan — the path, the act, the body and the manifest lines that record
  it — before either file is touched, so every failure the two halves raise
  leaves the disk as it was." No claim about every `err()` in `main()`.
- A trailing `[Nothing is written until both halves resolve](changelog/…)`
  line beneath the existing `[The payload names its actions]` one.

Present tense throughout; no account of prior behaviour. No `D2`/`D3`/`D5`
written.

### `CLAUDE.md` — exactly three edits

1. **`scripts/checkpoint.py` bullet.** "existence sampled before any write" →
   "existence sampled in the plan phase", and the whole-or-nothing guarantee
   added in the same breath with its scope: the two halves and their manifest,
   not every `err()` reachable from `main()` (`compose_sentinel`'s read-back
   named as firing after both applies, with the manifest already written), and
   `OSError` named as outside it. The bullet's `See` line now cites both
   changelog entries.
2. **`scripts/_checkpoint_lib.py` bullet.** "Shared by `checkpoint.py` (after
   a Write/Edit it just applied)" → "(on each half's resolved body, before
   anything is applied)". `write-stage.sh`'s half and the shared-function
   rationale untouched.
3. **Testing / `tests/test_checkpoint.py` bullet.** Count 128 → 139. "Edit
   application (`old_string` absent, ambiguous, successful)" → names the
   missing-file case too and says the three failures run over the same fixture
   as the positive, each asserting the task file survives with its original
   bytes and no manifest is written. The empty-body sentence gains the
   `edit`-to-empty route, "the one that reaches the emptiness rule through a
   computed body rather than one the payload states outright", beside the
   `clear` pair it already named.

No other `CLAUDE.md` bullet touched. m14–m18 left deferred.

## Citations re-derived (old line → what was actually found)

Every one was re-derived by `grep -n`; none of the runbook's recorded numbers
still held.

| runbook | actual | what is there |
| --- | --- | --- |
| `docs/design.md:240` | `docs/design.md:240` (unchanged) | the `apply_task`/`apply_todo` `file_path` sentence — the one number that did not move |
| `docs/design.md:243` | `docs/design.md:243` | `A violation exits non-zero naming the offending field.`, immediately above the `[The payload names its actions]` link line at `:244` |
| `CLAUDE.md:543` | `CLAUDE.md:541-544` | the `Removes a file whose resulting body is empty … existence sampled before any write` sentence spans four lines; `:543` is its middle |
| `CLAUDE.md:614` | `CLAUDE.md:614` | `Shared by `checkpoint.py` (after a Write/Edit it just applied) and` — held |
| `CLAUDE.md:802` | `CLAUDE.md:802` | `tests/test_checkpoint.py` (128 tests)` — held; the `Edit application` phrase is at `:821` and the empty-body sentence at `:822-826` |

## Test count, verbatim

```
$ pytest tests/test_checkpoint.py --collect-only -q
…
139 tests collected in 0.05s
```

Written as 139, not incremented from the page's stale 128.

## `just precommit`

Green, full run: jq manifest + settings lint, `shellcheck -x` over scripts +
`bin/` + `.bats`, `ruff check`, `ruff format --check`, `docformatter --check`,
`mypy`, `ty check`, `bats tests/*.bats` (164 ok), `pytest` (229 passed, 11
deselected — the `live` marker). Tail:

```
229 passed, 11 deselected in 45.98s
ok
```

## Amend

`HEAD`'s subject was verified as
`🐛 Item 1.1/1 — whole or nothing, and the edit-to-empty route stays intact`
before touching anything. The four files were staged and
`git commit --amend --no-edit` run — no `--no-verify`, every hook allowed to
run.

- before: `a0a0aae`
- **after: `99ce354`** — subject unchanged.

`git diff a0a0aae HEAD --stat` lists exactly the four files (`CLAUDE.md`,
`docs/changelog.md`, the new entry, `docs/design.md`);
`git diff a0a0aae HEAD --stat -- scripts/ tests/` is empty, so item 1.1's code
and tests are byte-for-byte as committed.

## End state

```
$ git status --porcelain
```

Empty at the moment of the check above; this report is the only file written
since, and it is untracked.
