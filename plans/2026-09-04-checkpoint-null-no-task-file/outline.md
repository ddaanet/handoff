# Outline — the checkpoint payload names its actions

Source brief: `plans/2026-09-03-brief-checkpoint-null-no-task-file.md`.
Classification: Moderate / Production — see `classification.md`.

The directory name is a write-time handle from the brief; the job has since
grown past it. What follows is the current shape.

## Scope

`"task": null` — the spelling an agent reaches for to mean *no task file* —
currently exits 0 and touches nothing. Rather than give `null` that meaning,
the payload stops overloading it: `task` and `todo` each carry their content
directly as a string, and the special cases are named by a tagged action.
FR6 (*file present ⟹ content pending*) is then satisfied by a form that says
what it does.

```
"task": "<content>" | {"action": "clear"}
"todo": "<content>" | {"action": "clear"} | {"action": "keep"}
                    | {"action": "edit", "old_string": "…", "new_string": "…"}
```

`file_path` goes: `apply_task`/`apply_todo` compose the real path from
`HANDOFF_ROOT` themselves, so the field was validated against a constant and
discarded — never load-bearing. Removing it also removes the failure mode its
guard existed to catch, since the agent can no longer name a path at all.

`null` becomes invalid on both fields, naming the field and the action to use
instead. That is the point: the defect being fixed is an agent choosing a
spelling that silently did the wrong thing, so the wrong spelling must fail
loudly rather than acquire a meaning. `null` stays valid on `continue`, where
it has exactly one meaning.

**IN:** `scripts/checkpoint.py`, `scripts/bash-post.sh`,
`tests/test_checkpoint.py`, both wrap-up SKILL.md bodies, `docs/design.md`,
`docs/changelog/` + its index, `CLAUDE.md`.

**OUT:** `write-stage.sh`, `is_empty_body`, the sentinel composer/parser pair,
the `autoname`/`restart` payloads (neither carries `task` or `todo`). No
back-compat branch for the old shape — user base of one, fix forward
(`no-transition-special-cases`).

## Decisions this outline applies

1. **A tagged union, not sentinel strings.** Bare `"@empty"`/`"clear"` tokens
   were weighed and rejected: a typo in a bare sentinel is indistinguishable
   from content and silently writes a one-line file — the original defect
   class at a new spelling. `{"action": "emty"}` is a schema error naming the
   field. This also folds todo's Edit form into the same union, replacing
   `validate_todo`'s `has_content`/`has_old`/`has_new` key-combination
   sniffing with one dispatch.
2. **Every payload field is required by key presence, with no default** —
   `task`, `todo`, `clear`, `compact`, `continue`, `rename`. One rule, no
   per-field carve-out. `{"action": "keep"}` is what expresses "this call says
   nothing about the list", so `todo`'s optionality is redundant. Both SKILL.md
   bodies already emit both fields, so no caller changes.
3. **Removal is unlink-if-present, and `D` records only a removal that
   happened.** Existence is sampled before any write; `{"action": "clear"}`
   writes nothing at all. This covers both routes to removal — the explicit
   clear, and a write whose body turns out empty under `is_empty_body` — in
   one shape, and keeps `apply_task` and `apply_todo` aligned.
4. **`bash-post.sh`'s `2>/dev/null` goes with it.** The phantom `D` was the
   only expected failure that redirect covered; with no manifest line naming a
   file that never existed, a failed `git add` is a real defect and is
   currently silent on both channels (a stranded `index.lock` surfaces as
   `staged 0, deleted 0`). Guarding the expected failure away rather than
   redirecting is the remedy `no-stderr-suppression` prescribes.

## Per-file changes

### `scripts/checkpoint.py`

- `validate_task`: replaced, not patched. The `file_path` block (275–290) and
  the `old_string`/`new_string` guard go — a bare string cannot carry either.
  Accepts a string or `{"action": "clear"}`; rejects `null`; requires the key.
- `validate_todo`: the largest change. `_todo_file_path` (294–304) is deleted
  outright; the `file_path` requirement (326–328) goes; the key-combination
  branching (316–340) collapses into a dispatch on `action`.
- `apply_task` / `apply_todo`: unlink-if-present, existence sampled first, `D`
  only on an actual removal.

### `scripts/bash-post.sh`

- Line 36: drop `2>/dev/null`; report a failed `git add` on both channels
  rather than dropping the path from the counts.

### `tests/test_checkpoint.py`

The suite is **not** inert under this change — the opposite. Counted: 61
`"task": None`, 57 `"todo": None`, 11 `task_write(...)` call sites, 25
`file_path` occurrences, none behind a payload factory. Roughly 130 mechanical
edits across 1893 lines, which slice 0 below reduces to four helper bodies.

- Delete (not invert) `test_task_content_null_no_file_path_noop` (~554) and
  `test_task_file_path_content_null_noop` (~572): both exercise forms that
  cease to exist. Inverting a test whose premise is gone leaves an
  absence-guard (`remove-cleanly-no-vestigial`).
- Delete the `file_path`-outside-root and `content`+`old_string` rows with the
  forms they cover.
- Add: `null` rejected by name on each field; each field's key absent rejected
  by name; an unknown `action` rejected by name; `{"action": "clear"}` against
  a pre-existing file removes it and records `D`; against a never-existed file
  removes nothing and records no `D`; `{"action": "keep"}` leaves the list
  alone.
- Amend `test_task_write_only_headings_removed_manifest_records_d` (~663) into
  the pre-existing and never-existed cases.

### `skills/handoff/SKILL.md` and `skills/precompact/SKILL.md`

`skills/handoff/SKILL.md:101-103` — "*`task` and `todo` are each the file's
content, or `null` when there is nothing to say for that file*" — is the
defect's origin: it tells the agent `null` means "nothing to say", which for
`task` reads as "no task file". `skills/precompact/SKILL.md:64-65` repeats it.
Both go, along with `handoff/SKILL.md:98`'s "*or omit the whole field with
null*", which conflates omitting a key with nulling it.

The replacement names the four actions instead of teaching a rule, and the
`<abs path to>/.claude/handoff-task.md` interpolation disappears from both
examples — the agent no longer composes a path it has to derive from a root it
cannot read. Shorter than what it replaces, so NFR3 is comfortable.

### `docs/design.md`, `docs/changelog/`, `CLAUDE.md`

- `docs/design.md:219-222` states the payload shape as a deliberate choice —
  `task`/`todo` "in the harness's own tool-call shape" — and this reverses that
  rationale. It takes a superseding pointer, not a wording edit.
- `docs/design.md`'s rejected-alternatives section takes the magic-string
  sentinel with its reasoning — a typo in a bare token is indistinguishable
  from content and is written as content. Nothing else in the repo carries
  that argument, and it is the one a future session will re-propose: the
  first shape considered at the proof pass was itself a bare sentinel.
- `docs/design.md:139-141` states **FR5** in Write-form/Edit-form vocabulary
  that ceases to exist. FR5's substance survives (incremental todo update is
  still supported) and is restated in action terms. FR6 is unaffected.
- `docs/changelog/2026-09-07-the-payload-names-its-actions.md` — the write-time
  record, leading with the motivating incident (2026-09-02, handoff 0.13.1: a
  frame stating a finished release was still unpublished survived into the next
  session), then the positive design. Rejected alternatives, five:
  error on `null`; document the `""` workaround; **make `null` delete** (this
  outline's own approach until 2026-09-07, and the minimal fix, so it is the
  one a future reader will re-propose); bare magic-string sentinels; keeping
  `file_path` as a cross-project guard.
- Its one-line entry in `docs/changelog.md` — required in the same pass.
- `CLAUDE.md`: the Layout section's description of the payload, and the Testing
  section's enumeration of covered schema rows, which names `content`+
  `old_string` and `file_path` outside `$root/.claude/` verbatim.

## Dependencies and phase shape

Five slices. Slice 0 is load-bearing: without it, the moment the schema changes
~118 payloads red for reasons unrelated to the behavior under test, and the new
assertions are invisible in that output (`genuine-red-not-missing-sut`).

- **Slice 0 — `general`, no behavior change.** Route every test payload through
  factory helpers (`task_content`, `task_clear`, `todo_keep`, `todo_edit`)
  emitting today's dicts. Suite green throughout; the diff is mechanical. This
  turns ~130 literal edits into four helper bodies.
- **Slice 1 — `tdd`.** The payload-layer rewrite, with the factories flipped to
  the new shapes. Red is then the new assertions plus the factories — a genuine
  assertion red, no stub needed.
- **Slice 2 — `inline`.** `bash-post.sh:36`. Coupled to slice 1 by cause;
  separate to keep the tdd slice single-purpose.
- **Slice 3 — `inline`.** Both SKILL.md bodies.
- **Slice 4 — `inline`.** `docs/design.md`, the changelog entry, its index
  line, `CLAUDE.md`.

## Verification

`just precommit` (lints, `shellcheck -x` — which covers `bash-post.sh` —
ruff/docformatter/mypy/ty, `bats tests/*.bats` + `pytest`).

**The producer and consumer of this schema go live at different times.**
`checkpoint.py` runs through the `bin/handoff-checkpoint` shim and is live the
moment it is written; both SKILL.md bodies are snapshotted at session start
(`stale-plugin-code`). Between slice 1 and a reload, a live session emits the
old payload into the new validator, which rejects it — so `/handoff` and
`/handoff:precompact` fail outright in the session doing the work. Loud, which
is the right failure, but the remedy is `/reload-plugins` for the bodies, or
`/handoff:restart`.

**A version bump is a delivery requirement, not a breakage question.** The
payload is an internal contract between two files shipping in the same plugin,
with no external producer, so it cannot desynchronize across a release
boundary — the markdown shape of neither output file changes and `CLAUDE.md`'s
breaking-change rule is untouched. But the marketplace cache is keyed by
version: a push under an unchanged version reaches no installed repo and
`/plugin update` re-fetches nothing. The release call stays my human partner's;
"no bump" is not among the outcomes that deliver the fix.

**Before dogfooding, establish which plugin root is loaded** — the
version-keyed cache or `--plugin-dir` — since it decides whether editing the
working tree changes anything live. `installed_plugins.json`, or grep the
transcript for `plugins/cache/<owner>/handoff/<version>/`. Then one real
`/handoff` call, the day it lands.
