# m4 fix — `is_empty_body` routes A and B

## 1. The predicate table

| Spelling | Old verdict | New verdict | Route |
|---|---|---|---|
| `"   "` (spaces only) | content (kept) | blank (skipped) | A |
| `"## Remaining"` | heading (skipped) | heading (skipped) | unchanged |
| `"# Task"` | heading (skipped) | heading (skipped) | unchanged |
| `"#"` | heading (skipped) | heading (skipped) | unchanged |
| `"###   "` (trailing spaces) | heading (skipped) | heading (skipped, via strip) | unchanged |
| `"#!/bin/sh"` | heading (skipped, wrongly removed) | content (kept) | B |
| `"#tag"` | heading (skipped, wrongly removed) | content (kept) | B |
| `"#######"` (seven `#`) | heading (skipped, wrongly removed) | content (kept) | B |
| `"   ## Task"` (indented heading) | content (kept — old test had no strip) | heading (skipped) | B-adjacent, deliberate consequence of stripping first, noted in the docstring |

## 2. Red evidence

Both suites run against unchanged `_checkpoint_lib.py`, before the fix.

```
$ VIRTUAL_ENV=.../.venv PATH=.../.venv/bin:$PATH pytest tests/test_checkpoint.py -k "whitespace_only or shebang_like" -v
...
>       assert not (repo / ".claude" / "handoff-task.md").exists()
E       AssertionError: assert not True
tests/test_checkpoint.py:916: AssertionError
...
>       assert not (repo / ".claude" / "handoff-todo.md").exists()
E       AssertionError: assert not True
tests/test_checkpoint.py:943: AssertionError
...
>       assert (repo / ".claude" / "handoff-task.md").is_file()
E       AssertionError: assert False
tests/test_checkpoint.py:969: AssertionError
=========================== short test summary info ============================
FAILED tests/test_checkpoint.py::test_task_write_whitespace_only_pre_existing_removed_manifest_records_d
FAILED tests/test_checkpoint.py::test_todo_write_whitespace_only_pre_existing_removed_manifest_records_d
FAILED tests/test_checkpoint.py::test_task_write_shebang_like_body_preserved_manifest_records_w
================= 3 failed, 2 passed, 142 deselected in 0.93s ==================
```

```
$ bats tests/hook-test.bats -f "whitespace-only"
1..1
not ok 1 write-stage (handoff-todo.md whitespace-only): removed and the removal staged
# (in test file tests/hook-test.bats, line 609)
#   `[ ! -e "$git_tmp/.claude/handoff-todo.md" ]' failed
```

All four fail on their own assertion (three pytest `AssertionError`s at the
exact lines being checked, one bats assertion), none at collection, fixture
setup, or a `127`.

## 3. What changed

`is_empty_body` (`scripts/_checkpoint_lib.py`) now strips each line before
testing it, and tests "is a heading" with a compiled ATX pattern instead of
`str.startswith("#")`:

```python
_ATX_HEADING = re.compile(r"#{1,6}(\s.*)?")

def is_empty_body(content: str) -> bool:
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped == "" or _ATX_HEADING.fullmatch(stripped):
            continue
        return False
    return True
```

`_ATX_HEADING.fullmatch` requires the whole (already-stripped) line to be
1-6 `#` followed by either nothing or whitespace-then-text — so `#!/bin/sh`,
`#tag`, and seven-or-more `#` all fail the match (the `#` run is not
followed by whitespace, or exceeds 6) and read as content, while `#`, `##
Remaining`, and an indented `## Task` (stripped first) all match.

Docstring now states the heading definition, the two route fixes, and the
deliberate consequence of stripping before testing (an indented heading
still counts as a heading) rather than the old two-line summary.

Tests added:

- `tests/test_checkpoint.py::test_task_write_whitespace_only_pre_existing_removed_manifest_records_d` (route A, task half)
- `tests/test_checkpoint.py::test_todo_write_whitespace_only_pre_existing_removed_manifest_records_d` (route A, todo half)
- `tests/test_checkpoint.py::test_task_write_shebang_like_body_preserved_manifest_records_w` (route B, task half)
- `tests/hook-test.bats`: `write-stage (handoff-todo.md whitespace-only): removed and the removal staged` (route A, bash caller)

No new test file or `just` recipe; all four rows landed inside the existing
files, beside their nearest structural siblings.

## 4. Mutation evidence

Backup: `/tmp/claude/m4-backup/_checkpoint_lib.py.good`, checksum
`2c0299e88caf7213e9974f096fdd2f8591739f37b19252f373abdcf26bf14f27` before
either mutation, matching after each restore (see below).

### Mutation 1 — blank test back to `line == ""`

```python
stripped = line.strip()
if line == "" or _ATX_HEADING.fullmatch(stripped):
```

```
$ pytest tests/test_checkpoint.py -v
...
FAILED tests/test_checkpoint.py::test_task_write_whitespace_only_pre_existing_removed_manifest_records_d
FAILED tests/test_checkpoint.py::test_todo_write_whitespace_only_pre_existing_removed_manifest_records_d
======================== 2 failed, 145 passed in 20.72s ========================

$ bats tests/hook-test.bats
...
not ok 52 write-stage (handoff-todo.md whitespace-only): removed and the removal staged
```

Exactly the three route-A rows red (2 pytest + 1 bats); every other row,
including route B's, stayed green.

Restore: `cp /tmp/claude/m4-backup/_checkpoint_lib.py.good scripts/_checkpoint_lib.py`.
Checksum after restore: `2c0299e88caf7213e9974f096fdd2f8591739f37b19252f373abdcf26bf14f27`
(matches). `git diff scripts/_checkpoint_lib.py` after restore showed only
the intended fix against the committed baseline (no mutation residue).

### Mutation 2 — heading test back to `startswith("#")`

```python
stripped = line.strip()
if stripped == "" or stripped.startswith("#"):
```

```
$ pytest tests/test_checkpoint.py -v
...
FAILED tests/test_checkpoint.py::test_task_write_shebang_like_body_preserved_manifest_records_w
======================== 1 failed, 146 passed in 16.26s ========================

$ bats tests/hook-test.bats
(no `not ok` lines — all 142 green)
```

Only the route-B row red; every other row, including both route-A rows,
stayed green.

Restore: same backup path. Checksum after restore matched
(`2c0299e8...f14f27` both sides). `git diff` after restore again showed only
the intended fix.

(The final on-disk file differs from that checksum only by the later
docstring-wording edits made to satisfy `docformatter`/`ruff`'s line-length
rules — no behavioral change; see the precommit tail below for the actual
current state.)

## 5. Green evidence

```
$ VIRTUAL_ENV=/Users/david/code/handoff/.venv PATH=/Users/david/code/handoff/.venv/bin:$PATH just precommit
jq . .claude-plugin/plugin.json > /dev/null
jq . hooks/hooks.json > /dev/null
jq . .claude/settings.json > /dev/null
shellcheck -x .bin/* bin/* scripts/*.sh tests/*.bats
ruff check scripts tests
All checks passed!
ruff format --check scripts tests
11 files already formatted
docformatter --check scripts/*.py tests/*.py
mypy
ty check
All checks passed!
bats tests/hook-test.bats tests/checkpoint.bats
1..166
...
ok 166 bash-post: one staged and one failed -> both clauses compose in order
pytest
...
===================== 237 passed, 11 deselected in 45.73s ======================
ok
```

Full gate green: lint (jq/shellcheck/ruff/docformatter/mypy/ty), 166/166
bats, 237/237 pytest.

## 6. The loader-gate question

Found one surviving route, out of scope to fix here per the brief:
`write-guard.sh` is wired as `PreToolUse(Write|Edit)` only (see its own
header comment and `hooks/hooks.json`) — it never sees the Bash tool. An
agent (or any other process) writing `.claude/handoff-task.md` or
`.claude/handoff-todo.md` directly via Bash (e.g. `printf '   ' >
.claude/handoff-task.md`) bypasses both write-guard.sh and `is_empty_body`
entirely, and `handoff_frame`'s `-s` test (byte-length only) would still
treat the resulting whitespace-only file as present and inject it.

A second, narrower route: a file already on disk from before this fix (or
from any such Bash bypass) is not swept retroactively by anything — the fix
only changes what future writes through `checkpoint.py` and
`write-stage.sh` produce, not what already exists.

I looked by reading `scripts/write-guard.sh` in full (it matches `Write|Edit`
tool events via `handoff_match_target`, with no Bash-tool matcher), grepping
`hooks/hooks.json` for every hook wired to `PreToolUse` and confirming
`write-guard.sh` is registered only for `Write|Edit`, and confirming both
`checkpoint.py` (`:455`, via `is_empty_body` on the resolved body before
writing) and `write-stage.sh` (`:24`, via the `--is-empty-body` CLI) are the
only two writers that route through the fixed predicate. No route through
either of those two writers survives; the Bash-bypass and stale-file routes
are outside them.

## 7. Anything found and not touched

- **Regression guard already covered.** The heading-only-body row the brief
  asked me to check for was already present:
  `test_task_write_only_headings_pre_existing_removed_manifest_records_d`
  (`tests/test_checkpoint.py:852`) uses
  `task_content("## Current task\n\n## Open decisions\n")`, which is exactly
  a heading-only body, and asserts removal + `D` manifest line. I did not add
  a duplicate row.
- **No existing row encoded the old (wrong) behaviour.** The full suite was
  green before this change and stayed green after — the only reds were the
  new rows themselves during red-phase and mutation, confirmed above. No
  fixture had to be changed.
- Nothing else found and left untouched beyond the loader-gate finding in
  §6, which is reported per the brief rather than fixed.

## Files touched

- `scripts/_checkpoint_lib.py`
- `tests/test_checkpoint.py`
- `tests/hook-test.bats`

Tree left dirty, not committed, per the brief.
