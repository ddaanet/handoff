# Phase 2 checkpoint review — Item 2.1, `bash-post.sh` stops swallowing a failed stage

Reviewed `5cd0b82` against the runbook item, FR7, D4, NFR1 and NFR2. All fixes
applied; not committed. `just precommit` green after the fixes: **164 bats**
(was 162 — two rows added), **218 pytest passed + 11 deselected**, shellcheck
clean. Working tree carries only `scripts/bash-post.sh`, `tests/checkpoint.bats`
and this report.

## Findings

### 1 — MAJOR (fixed). The guard reintroduced the swallow the item exists to remove.

`scripts/bash-post.sh:46` as committed:

```sh
if [ "$op" = "D" ] && [ -z "$(git -C "$cwd" ls-files -- "$rel")" ]; then
    continue
fi
```

A command substitution that *fails* does not trip `set -e` from inside a `[ ]`
test — verified empirically, not reasoned: with `git -C /nonexistent ls-files`
the script printed git's fatal to stderr, evaluated `-z ""` as true, took the
`continue`, and ran on to exit 0. So a `D` line in a repo git cannot read at all
(a `.git` that will not parse, a missing or unreadable index, wrong permissions)
was indistinguishable from the benign never-entered-the-index case: silently
skipped, uncounted, absent from both channels.

That is exactly the class D4 targets, and it is not the benign case the guard
was written for — `git add -f` could not have staged into that repo either, so
the honest outcome is the one a `W` line already gets in the same repo: reported
as failed. The committed shape left `D` lines as the one path still swallowing a
genuine failure, and inconsistently with `W` lines beside them.

Fixed by splitting the guard so ls-files' own exit status is read rather than
inferred from its empty output:

```sh
if [ "$op" = "D" ]; then
    if ! indexed="$(git -C "$cwd" ls-files -- "$rel")"; then
        failed+=("$rel")
        continue
    fi
    [ -n "$indexed" ] || continue
fi
```

The `!`-negated assignment is the form whose status *is* the substitution's, and
it is inside an `if` condition, so `set -e` is exempt (SC2155 does not apply —
no `local`/`export`/`declare`; shellcheck clean). Valid on bash 3.2: `!` negates
a pipeline and a bare assignment is a simple command.

Encoded as `tests/checkpoint.bats` row *"bash-post: D whose index cannot be read
-> reported, not swallowed by the guard"*. Its fixture writes a garbage `.git`
**file**, so ls-files fails wherever `BATS_TEST_TMPDIR` happens to sit — an
enclosing repo cannot rescue it into a successful, empty `ls-files`, which a
plain non-repo directory could. `handoff_root_read`'s fast path returns before
python3 or git touch that `.git` (cwd == `CLAUDE_PROJECT_DIR`), so the fixture
does not perturb root resolution. The row asserts the named path on both
channels, no `Leave them staged` clause, and non-empty stderr — deliberately not
git's wording for this one, since "invalid gitfile format" is less stable than
the `index.lock` path row 21 pins.

**Mutation-checked**: folding the guard back into the single committed condition
reds row 22 alone; rows 19–21 and 23 stay green. Restored from a backup verified
non-empty before use, and the restore asserted by grep rather than assumed.

### 2 — MINOR (fixed). The four-combination composition was verified by reading, not encoded.

Concern 6 of the dispatch. Reading confirms all four compose correctly, but only
three were reachable by the suite, and the one that was not is the one the
restructure could break: *something staged **and** something failed*, where the
failure clause, the sentence-closing period and the `Leave them staged` clause
all meet.

Rows 21 and 22 cannot catch a period regression — with the period moved back
into the initial assignment, `agent_ctx` reads `…deleted: none.; failed to
stage: X` and their `test("failed to stage: …")` still matches. Added row
*"bash-post: one staged and one failed -> both clauses compose in order"*,
pinning the full ordered string on both channels. Fixture: a manifest naming one
path on disk and one not, which is the cheapest deterministic way to fail one
`git add` while another succeeds (an empty directory does **not** work — `git
add -f` on one exits 0, verified). The row's comment says plainly that the
checkpoint does not compose that manifest itself and the row is about the
composition, not the cause.

**Mutation-checked**: moving the trailing `.` back into the initial `agent_ctx`
assignment reds row 23 alone.

### 3 — MINOR (fixed). The `${failed[*]}` residual bound was implied, not stated.

Whitespace is the one thing here that must not be left to inference. Audited
every use of `rel`: `op="${line%% *}"` / `rel="${line#* }"` split on the first
space only and so carry a spaced remainder intact; `ls-files`, `add`, and the
array append are all quoted. Correct as written.

`${failed[*]}` joins on a space, which *would* be ambiguous for several failed
paths containing spaces. It cannot arise: since Phase 1, `checkpoint.py` has no
`file_path` field at all (`grep file_path scripts/checkpoint.py` → nothing) and
composes every manifest line from `HANDOFF_REL_TASK`/`HANDOFF_REL_TODO`, so the
only two names that ever reach this loop are `.claude/handoff-task.md` and
`.claude/handoff-todo.md`. Per the convention, that bound is now stated in a
comment rather than left implied, and named as the same bound the pre-existing
`${staged[*]}`/`${deleted[*]}` joins already rely on.

## Checked and found sound — no change

- **D4 satisfied.** No `2>/dev/null` survives in the file; the one match is
  inside a comment describing what was removed.
- **NFR2, hot path.** The `ls-files` subprocess sits behind the manifest-presence
  gate at `scripts/bash-post.sh:24`, which exits before the root is even
  resolved, and behind `[ "$op" = "D" ]`, which short-circuits. A `W` line — the
  common case — pays nothing new. Row 15 still asserts the negative path never
  resolves the root.
- **`set -e` and the `if` conditions.** Both `git` calls remain in `if`
  conditions, so a non-zero exit is handled rather than fatal. The one
  substitution that was *not* in an `if` condition is finding 1, now fixed.
- **bash 3.2.** `failed=()` is fine. `${#failed[@]}` on an empty array is a
  length query, not the `${arr[@]}` empty-array unbound bug the repo's
  `${DRIVE_BEFORE[@]+…}` idiom exists for — and it is the pre-existing spelling
  of `${#staged[@]}` two lines up, so it adds no new exposure. `${failed[*]}` is
  expanded only inside the `${#failed[@]} -gt 0` guard, so the empty case never
  reaches it. No `mapfile`, no `${var,,}`, no associative arrays introduced.
- **Row 21's stderr split is honest.** bats merges stderr into `$output` by
  default, and git's explanation now lands there, so an unsplit run would break
  the `jq` parse rather than assert anything. Capturing it separately is what
  lets the row assert both halves of the contract — the named path says *which*,
  git's message says *why*. `grep -q 'index.lock'` pins a filename inside the
  path git prints, not prose wording, so it is durable; row 23's `did not match
  any files` is long-standing git wording and acceptable at the same bar.
- **Rows 19/20 are a genuine pair.** One fixture, differing only in whether the
  path entered the index; row 20 is what the guard exists for and reds without
  it. Neither can pass vacuously.
- **NFR1 untouched.** The hook still does the git work; nothing moved into the
  agent's sandboxed Bash.

## Accepted consequence, worth naming for Phase 4

A handoff root that is not a git repository now reports `failed to stage:
.claude/handoff-task.md` on both channels at every checkpoint, plus git's own
fatal on stderr, where it previously read `staged 0`. That is the item's stated
intent applied consistently, and the plugin's design already assumes git
(`git add -f`, both paths gitignored). Not a defect — but the failure channel is
new user-visible behaviour, and `CLAUDE.md`'s description of `bash-post.sh`
mentions neither it nor the index guard. Phase 4 owns that rewrite.

## Process note

`$TMPDIR` is **unset** in this environment. A probe run as `cd "$TMPDIR" && …`
silently landed in the repo root and created a nested git repo there; caught and
removed, tree verified clean. Same failure mode the dispatch warned about
earlier in this run. Use `mktemp -d` here, never `$TMPDIR`.
