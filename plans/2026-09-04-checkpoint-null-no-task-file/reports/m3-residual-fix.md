# M3 residual fix — top-level unknown payload keys

**Date:** 2026-09-14
**Subject:** `scripts/checkpoint.py` silently discarding a superfluous
top-level payload key (the residual half of M3, as scoped in
`reports/fix-status-audit.md`, `### M3`).

## 1. Equivalence audit

Claim to verify: the union of every key any skill takes —
`skill, commit, rename, task, todo, clear, compact, continue` — is exactly
the set of keys legal under *some* skill, and every key illegal under a given
skill is already rejected there by an existing, more specific validator. This
is what justifies a flat (non-skill-dependent) unknown-key check placed
immediately after `validate_skill`.

| key | forbidden under | rejected by | file:line |
|---|---|---|---|
| `skill` | (none — every skill requires it) | — | — |
| `commit` | autoname | `validate_autoname_forbidden_fields` loop | `scripts/checkpoint.py:157-161` (entry `"commit"` in the tuple, `:159`) |
| `commit` | restart | `validate_restart_forbidden_fields` loop | `scripts/checkpoint.py:164-172` (entry `"commit"`, `:170`) |
| `rename` | precompact | `validate_rename`, `if skill in ("precompact", "restart"): if "rename" in payload: err(...)` | `scripts/checkpoint.py:181-184` |
| `rename` | restart | `validate_restart_forbidden_fields` loop (entry `"rename"`, `:170`) **and** `validate_rename` (`:181-184`) — the forbidden-fields check runs first in `main` (`:571-572` before `:574`), so it is the one that actually fires | `scripts/checkpoint.py:164-172`, `:181-184` |
| `task` | autoname | `validate_autoname_forbidden_fields` loop (entry `"task"`, `:159`) | `scripts/checkpoint.py:157-161` |
| `task` | restart | `validate_restart_forbidden_fields` loop (entry `"task"`, `:170`) | `scripts/checkpoint.py:164-172` |
| `todo` | autoname | `validate_autoname_forbidden_fields` loop (entry `"todo"`, `:159`) | `scripts/checkpoint.py:157-161` |
| `todo` | restart | `validate_restart_forbidden_fields` loop (entry `"todo"`, `:170`) | `scripts/checkpoint.py:164-172` |
| `clear` | precompact | `_build_precompact_transition`, `if "clear" in payload: err(...)` | `scripts/checkpoint.py:228-230` |
| `clear` | autoname | `validate_autoname_forbidden_fields` loop (entry `"clear"`, `:159`) | `scripts/checkpoint.py:157-161` |
| `clear` | restart | `validate_restart_forbidden_fields` loop (entry `"clear"`, `:170`) | `scripts/checkpoint.py:164-172` |
| `compact` | handoff | `_build_handoff_transition`, `if "compact" in payload: err(...)` | `scripts/checkpoint.py:216-218` |
| `compact` | autoname | `validate_autoname_forbidden_fields` loop (entry `"compact"`, `:159`) | `scripts/checkpoint.py:157-161` |
| `compact` | restart | `validate_restart_forbidden_fields` loop (entry `"compact"`, `:170`) | `scripts/checkpoint.py:164-172` |
| `continue` | autoname | `validate_autoname_forbidden_fields` loop (entry `"continue"`, `:159`); `validate_continuation` itself returns `""` early for autoname (`:248-249`) and does **not** check key presence there, so the forbidden-fields call — which runs earlier in `main`, `:570` — is what actually rejects it | `scripts/checkpoint.py:157-161`, `:246-249` |

`main`'s call order (`scripts/checkpoint.py:565-576`, pre-fix numbering) is
`validate_skill` → (`validate_autoname_forbidden_fields` if autoname /
`validate_restart_forbidden_fields` if restart) → `validate_commit_mode` →
`validate_rename` → `build_transition` (which dispatches to
`_build_handoff_transition` / `_build_precompact_transition`) →
`validate_continuation`. I traced each row above against that order to
confirm which validator actually fires first when two could plausibly
reject the same key (only `rename` under `restart` and `continue` under
`autoname` had that overlap; both resolve to the forbidden-fields loop
firing first, consistent with the brief's framing).

**Verified, no gap found.** Every union key is rejected under every skill
that does not take it, by an existing validator, before the new flat check
would even need to run for that case. The flat check's actual job is
narrower and disjoint from all of the above: catching a key *outside* the
eight-key vocabulary altogether (a typo such as `"tasks"`), which none of
the per-key validators above is positioned to name, since none of them
scans for arbitrary unrecognized keys — each only checks for specific
*known* key names showing up under the wrong skill.

## 2. Red evidence

Command:

```
cd "/Users/david/code/handoff" && VIRTUAL_ENV="/Users/david/code/handoff/.venv" PATH="/Users/david/code/handoff/.venv/bin:$PATH" pytest tests/test_checkpoint.py -k "test_top_level_unknown_key" -v
```

Output (against `checkpoint.py` before any implementation change — the four
new tests only, tree otherwise unchanged):

```
        """
        repo = make_repo(tmp_path)
        payload = {
            "skill": "handoff",
            "commit": "with-commit",
            "rename": "T",
            "clear": False,
            "continue": None,
            "task": task_clear(),
            "todo": todo_keep(),
            "bogus": "x",
        }
        result = run_checkpoint(repo, payload)
>       assert result.returncode == 2
E       AssertionError: assert 0 == 2
E        +  where 0 = CompletedProcess(args=['/Users/david/code/handoff/.venv/bin/python', '/Users/david/code/handoff/scripts/checkpoint.py'], returncode=0, stdout='', stderr='').returncode

tests/test_checkpoint.py:612: AssertionError
______________ test_top_level_unknown_key_errors_under_precompact ______________

tmp_path = PosixPath('/tmp/claude-1000/pytest-of-david/pytest-295/test_top_level_unknown_key_err1')

    def test_top_level_unknown_key_errors_under_precompact(tmp_path: Path) -> None:
        repo = make_repo(tmp_path)
        payload = {
            "skill": "precompact",
            "commit": "without-commit",
            "compact": False,
            "continue": None,
            "task": task_clear(),
            "todo": todo_keep(),
            "bogus": "x",
        }
        result = run_checkpoint(repo, payload)
>       assert result.returncode == 2
E       AssertionError: assert 0 == 2
E        +  where 0 = CompletedProcess(args=['/Users/david/code/handoff/.venv/bin/python', '/Users/david/code/handoff/scripts/checkpoint.py'], returncode=0, stdout='', stderr='').returncode

tests/test_checkpoint.py:628: AssertionError
_______________ test_top_level_unknown_key_errors_under_autoname _______________

tmp_path = PosixPath('/tmp/claude-1000/pytest-of-david/pytest-295/test_top_level_unknown_key_err2')

    def test_top_level_unknown_key_errors_under_autoname(tmp_path: Path) -> None:
        repo = make_repo(tmp_path)
        payload = {"skill": "autoname", "rename": "A Side Conversation", "bogus": "x"}
        result = run_checkpoint(repo, payload)
>       assert result.returncode == 2
E       AssertionError: assert 0 == 2
E        +  where 0 = CompletedProcess(args=['/Users/david/code/handoff/.venv/bin/python', '/Users/david/code/handoff/scripts/checkpoint.py'], returncode=0, stdout='', stderr='').returncode

tests/test_checkpoint.py:636: AssertionError
_______________ test_top_level_unknown_key_errors_under_restart ________________

tmp_path = PosixPath('/tmp/claude-1000/pytest-of-david/pytest-295/test_top_level_unknown_key_err3')

    def test_top_level_unknown_key_errors_under_restart(tmp_path: Path) -> None:
        """Guard against a vacuous pass on the generic "unknown skill" message.
    ...
        """
        repo = make_repo(tmp_path)
        payload = {"skill": "restart", "continue": None, "bogus": "x"}
        result = run_checkpoint(repo, payload)
>       assert result.returncode == 2
E       AssertionError: assert 0 == 2
E        +  where 0 = CompletedProcess(args=['/Users/david/code/handoff/.venv/bin/python', '/Users/david/code/handoff/scripts/checkpoint.py'], returncode=0, stdout='', stderr='').returncode

tests/test_checkpoint.py:653: AssertionError
=========================== short test summary info ============================
FAILED tests/test_checkpoint.py::test_top_level_unknown_key_errors_under_handoff
FAILED tests/test_checkpoint.py::test_top_level_unknown_key_errors_under_precompact
FAILED tests/test_checkpoint.py::test_top_level_unknown_key_errors_under_autoname
FAILED tests/test_checkpoint.py::test_top_level_unknown_key_errors_under_restart
====================== 4 failed, 140 deselected in 1.20s =======================
```

All four fail on the assertion itself (`assert 0 == 2`) — not a collection
error, not a fixture error. This is the evidence the four rows exercise the
gap: with `"bogus"` (a key outside the union, present alongside an
otherwise-well-formed payload for each skill), unchanged `checkpoint.py`
exits 0 and writes nothing to stderr.

## 3. What changed

**`scripts/checkpoint.py`** — one new module-level constant and one new
function, called from `main()`:

- `_TOP_LEVEL_KEYS`, the flat 8-tuple
  `("skill", "commit", "rename", "task", "todo", "clear", "compact",
  "continue")`, placed immediately above the function that reads it.
- `validate_top_level_keys(payload)` — computes
  `sorted(k for k in payload if k not in _TOP_LEVEL_KEYS)`; if non-empty,
  calls `err("payload", ...)` naming the first (alphabetically-sorted)
  extra key. Docstring states why the set is flat rather than
  skill-dependent (mirrors the audit's reasoning in §1 above).
- Error message shape, mirroring `_reject_unknown_keys`'s existing style:

  ```
  handoff-checkpoint: payload: unknown key "bogus", takes only "skill", "commit", "rename", "task", "todo", "clear", "compact", "continue"
  ```

- Call site: `main()`, immediately after `skill = validate_skill(payload)`
  and before the `if skill == "autoname":` branch — exactly where the brief
  specified, so it fires ahead of every skill-specific validator and cannot
  shadow their messages (it only fires at all for a key none of them checks
  for).

No other script, and no bats test, was touched — the equivalence audit in
§1 found no gap, so `_checkpoint_lib.py` and the bats suite were left alone
per the brief's scope.

**`tests/test_checkpoint.py`** — four new test functions, added in the
"Schema validation (FR2)" section, right after
`test_malformed_json_errors_naming_payload` and before the existing
`task_or_todo_null_or_absent` parametrized test:

- `test_top_level_unknown_key_errors_under_handoff`
- `test_top_level_unknown_key_errors_under_precompact`
- `test_top_level_unknown_key_errors_under_autoname`
- `test_top_level_unknown_key_errors_under_restart`

Each builds an otherwise-valid payload for its skill and adds one
superfluous key, `"bogus": "x"` — a name chosen because it cannot appear in
any other error message any of these four payloads could produce (unlike
`"tasks"`/`"todos"`, which read as plausible intentional typos of existing
fields and would not by themselves prove the *new* check fired rather than
some other path). Each asserts `returncode == 2` and `"bogus" in
result.stderr`. The `restart` row additionally asserts
`'must be "handoff"' not in result.stderr`, ruling out the generic
"unknown skill" message explicitly — that message's own fixed vocabulary
lists all four skill names including "restart", so an assertion on
`"restart" in stderr` alone would be vacuous; this mirrors the existing
guard in `test_restart_session_id_unset_errors`.

Ran `docformatter --in-place tests/test_checkpoint.py` once, to rewrap two
docstrings (line width only — no content change) after adding the tests;
this was required by the precommit gate's `docformatter --check` step.

## 4. Green evidence

Command:

```
cd "/Users/david/code/handoff" && VIRTUAL_ENV="/Users/david/code/handoff/.venv" PATH="/Users/david/code/handoff/.venv/bin:$PATH" just precommit
```

Tail of the output:

```
bats tests/hook-test.bats tests/checkpoint.bats
1..165
ok 1 handoff_root: worktree cwd -> worktree root
...
ok 165 bash-post: one staged and one failed -> both clauses compose in order
pytest
============================= test session starts ==============================
platform linux -- Python 3.14.3, pytest-9.0.3, pluggy-1.6.0
rootdir: /Users/david/code/handoff
configfile: pyproject.toml
testpaths: tests
collected 245 items / 11 deselected / 234 selected

tests/test_checkpoint.py ............................................... [ 20%]
........................................................................ [ 50%]
.........................                                                [ 61%]
tests/test_drive_when_idle.py ..............................             [ 74%]
tests/test_watcher_lib.py .............................................. [ 94%]
...                                                                      [ 95%]
tests/test_worktree_root.py ...........                                  [100%]

===================== 234 passed, 11 deselected in 47.97s ======================
ok
```

All 165 bats rows report `ok` (none omitted above; full log was inspected,
not just the tail) and the pytest suite is 234 passed / 11 deselected (the
11 deselected are the `live`-marker TUI-conformance tests, excluded from
`precommit` by design). `jq`, `shellcheck -x`, `ruff check`, `ruff format
--check`, `docformatter --check`, `mypy` and `ty check` all reported clean
ahead of the test run (visible in the full transcript; the tail above picks
up from the bats run for space). Also re-ran the four new rows in isolation
post-fix (`-k "test_top_level_unknown_key"`): 4 passed.

## 5. Alternatives weighed

**Flat union set vs. a per-skill legal-key set.** A per-skill check (e.g. a
dict mapping each of the four skill names to its own allowed-key tuple,
checked once `skill` is known) would give a tighter error for the *known-key
under wrong-skill* case — but that case is already fully handled, with a
better message, by the five existing forbidden-field / transition-builder
validators audited in §1. Adding a second, skill-dependent check ahead of
them would not close any additional gap; it would only race those
validators for the same inputs, and because it would necessarily run first
(there is no later point to hook it that isn't inside one of those
functions), it would *win* that race and replace their specific wording
("forbidden when skill is X", "must be true or false", the transition- and
action-aware messages) with a generic "unknown key" message — a strict
regression in diagnostic quality, and one that would have broken existing
tests asserting on the specific wording (e.g.
`test_every_boundary_field_is_schema_error_under_autoname` asserts both the
field name and the literal string `"autoname"` in stderr; a flat "unknown
key" message doesn't carry the skill name). The flat set has no such
collision because its only job — by construction, given the audit — is keys
that are illegal under *every* skill, i.e. genuinely outside the vocabulary.
So the choice isn't "flat is simpler, per-skill is more correct, we traded
precision for LOC" — the per-skill variant is strictly worse here, because
its added precision has no case left to apply to; every case it could catch
is already caught, better, upstream of where it would run.

The remaining design question was purely mechanical: catch the residual gap
*before* or *interleaved with* the existing checks. Before (`main`,
immediately after `validate_skill`) was chosen because it is
non-invasive — one call, one early exit, nothing else in the function
touched — and because "immediately after we know the skill, reject anything
outside the whole vocabulary" reads as the natural coarse-then-fine
validation order: reject garbage input before spending five more validator
calls interpreting it under a specific skill's rules.

**Where to compute the key set** — a module-level tuple vs. re-deriving it
from the union of each skill's own allowed-field lists (which exist
scattered across `validate_autoname_forbidden_fields`,
`validate_restart_forbidden_fields`, etc., each as "what's forbidden", not
"what's allowed"). Deriving it programmatically would require inverting
five different forbidden-field lists (four of which are for different
skills and phrased as exclusions, not inclusions) into one union — more
code, and a second, implicit definition of the same vocabulary the
docstring already states as a design invariant that plugin.json's
version-bump discipline already treats as a breaking-change surface (per
the file's own header comment about `HANDOFF_REL_*` being "kept in sync by
hand rather than sourced" for the same class of frozen-in-practice
constant). A literal tuple, defined once beside the function that reads it,
is the more honest representation: it names the actual invariant instead of
computing an artifact of five unrelated exclusion lists that happen to
union to it.

## 6. Anything found and not touched

Nothing. The equivalence audit found no gap in the five existing validators
— every union key is already rejected under every skill that forbids it,
with a message more specific than the new check's. No other script,
docstring, or test needed a change beyond the ones above. Per scope, no
documentation (`docs/changelog.md`, `docs/changelog/`, `docs/design.md`,
`CLAUDE.md`, `skills/`, or this job's other reports) was written or edited,
and nothing was committed — the working tree is left dirty for review.
