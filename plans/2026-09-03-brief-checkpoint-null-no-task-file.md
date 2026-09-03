## Brief: checkpoint should accept `null` as "no task file", not "leave the file alone"

2026-09-03

### Decisions

- `"task": null` — and its documented sibling `"task": {"file_path": …,
  "content": null}` — must mean **no task file**, with the same outcome as
  `"content": ""`: the file is removed and the removal staged (FR6). Today both
  forms are a silent no-op.
- The change is scoped to the **task** file. See the open question below on
  whether `todo` follows; the recommendation is that it does not.

### Constraints

- FR6 states the invariant this breaks: *"A file whose body is empty is removed
  … File present ⟹ content pending."* A `null` that leaves a stale
  `handoff-task.md` on disk violates the second half directly.
- `skills/handoff/SKILL.md` (line ~98) documents the field as *"task content, or
  omit the whole field with null"*, and the prose under it says *"the checkpoint
  decides absence from content, not from a wipe"* — i.e. `null` is the
  documented way to say "nothing here", and the agent is told **not** to pass an
  empty string. `skills/precompact/SKILL.md` (line ~74) says the same. The
  implementation and the documented contract disagree; the docs are right.
- The failure is silent, which is what makes it worth fixing rather than
  documenting around. The checkpoint exits 0 and the manifest hook reports
  `staged: none; deleted: none` — indistinguishable from a successful clear.

### Rejected approaches

- **Erroring on `null` to force an explicit `""`.** It would surface the bug,
  but it contradicts both SKILL.md bodies, which actively instruct the agent to
  pass `null` and never mention `""`. Fixing the callers to say `""` means the
  agent writes a wipe where the design says it should express absence.
- **Documenting the `""` workaround in the skill bodies instead.** Same
  objection, plus it leaves `null` as a live silent no-op for anyone following
  the older wording.

### Additional context

**Observed first-hand, 2026-09-02, handoff 0.13.1, in a consumer repo.** At the
end of a release session with nothing left pending, the handoff skill was run
with `"task": null, "todo": null`. Exit 0, manifest `staged: none; deleted:
none`, and both `.claude/handoff-task.md` and `.claude/handoff-todo.md` survived
untouched with the *previous* session's content — a frame stating the release was
still unpublished. Re-running with `"content": ""` on both deleted them
correctly (`deleted: .claude/handoff-task.md .claude/handoff-todo.md`). Left
uncorrected, the next session loads a frame describing finished work as pending,
which is the redo-the-work failure the todo-file rules exist to prevent.

**Where the behaviour lives.** `scripts/checkpoint.py`:

- `validate_task` (~line 264) returns `("none", "")` both when `task is None`
  (~267) and when `"content" in task and task.get("content") is None` (~273).
- `apply_task` (~line 358) returns `[]` for any action that is not `"write"`, so
  nothing is written, unlinked, or added to the manifest.
- `validate_todo`/`apply_todo` (~307, ~370) mirror this.

The delete path already exists and is correct — `apply_task` writes the content,
then `lib.is_empty_body(content)` (in `scripts/_checkpoint_lib.py`, ~line 23)
triggers `path.unlink()` and a `D` manifest line. The fix routes the `null`
forms into that path rather than into `"none"`.

**The open question the implementer must settle: does `todo` follow?**

`tests/test_checkpoint.py::test_todo_null_untouched_list_left_alone` (~line 822)
pins the current behaviour deliberately: a `null` todo with an existing list on
disk leaves it intact. That is not an oversight — FR4 calls `handoff-todo.md` *"a
scratch list by design. The agent edits it freely all session; the checkpoint is
only the wrap-up path."* Making `null` delete would let a checkpoint that simply
says nothing about todo wipe a list the agent maintained by hand.

The asymmetry resolves it cleanly, and FR5 already states it: *"The task file is
authored whole, so it takes the Write form only."* A whole-authored file has no
"leave my edits alone" case, so `null` there can only mean absent. The todo file
is incrementally edited and has the Edit form precisely so it can be changed
without regeneration — so `null` meaning "don't touch" is coherent for it.

**Recommendation:** change `task` only; leave
`test_todo_null_untouched_list_left_alone` standing. Then update the two SKILL.md
bodies so the asymmetry is stated rather than inferred — as written, both files
describe `null` identically for the two fields, which is what produced the wrong
call in the first place. If the todo file should also clear, that needs a
separate way to say "nothing pending" that is distinct from "I am not speaking
about todo this call".

**Test surface to check before changing anything.** Roughly 25 tests in
`tests/test_checkpoint.py` pass `"task": None` / `"todo": None` as filler while
testing unrelated things (rename validation, cwd drift, commit modes). None of
them create the files first, so the new delete path must tolerate a missing file
— `unlink(missing_ok=True)` — and must **not** emit a `D` manifest line when
there was nothing to delete, or those tests will fail on manifest assertions.
`test_task_file_path_content_null_noop` (~572) and
`test_task_content_null_no_file_path_noop` (~554) assert the current no-op
directly and will need inverting.
