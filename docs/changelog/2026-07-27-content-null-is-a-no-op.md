# `{"content": null}` is a no-op, not "content supplied" (2026-07-27)

`checkpoint.sh` distinguishes Write-form-with-content from field-absent by key
presence (`field_has_key task content`), not by the key's value. That's right
for distinguishing Write from Edit on `todo`, but wrong for `content` itself:
an agent that sends `{"file_path": "…", "content": null}` — or bare
`{"content": null}` — meant "nothing to write here," the same as sending
`task: null`. Key-presence validation instead treated `content` as supplied,
so `jq -r '.task.content'` (or `.todo.content`) ran on a JSON `null` and
printed the literal four-character string `"null"`, which got written into
`handoff-task.md`/`handoff-todo.md` as corrupted body text — silently, since
this passed schema validation and even satisfied the `file_path`-required
check when `file_path` happened to be present too.

The fix: both `validate_task` and `validate_todo` short-circuit to a no-op
(`return 0`, action stays `none`) as soon as `content` is present and
`field_is_null` on it — before the `file_path`-required check, so `file_path`
is not required for what is, in effect, an absent field. `todo`'s
short-circuit only fires when `old_string`/`new_string` are also absent, so
it can't shadow a genuine Edit-form schema error. Both reuse the existing
`field_is_null` helper, which already accepts a dotted path
(`field_is_null task.content` → `.task.content == null`) — no new helper
needed. Relaxation applies to both fields for consistency, not just the one
where the bug was first noticed.
