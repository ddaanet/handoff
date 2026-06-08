# Bats-core best practices (bare bats-core, no helper libs)

Audit rubric for a bats test suite running on **Bats 1.11.1** with
**bats-core only** — `bats-assert`, `bats-support`, `bats-file` are NOT
installed. Every recommendation below works with bare bats-core:
`run`, `$status`, `$output`, `$lines`, `$stderr`, `setup`/`teardown`/
`setup_file`/`teardown_file`, `load`, `skip`,
`bats_require_minimum_version`, and plain `[ … ]` / `[[ … ]]` / `jq` /
`grep` assertions. Do **not** expect or accept `assert_output`,
`assert_success`, etc. — the idiomatic bare-bats equivalents are given
in each section.

Sources are official bats-core docs (cited inline). Skim the numbered
sections, then audit against the **Reviewer checklist** at the end.

---

## 1. The masked-failure pitfall (most important)

Bats runs each `@test` body under `set -e` errexit. On the **Bats
1.11.1 + Bash 5.2** toolchain this repo uses, a failing **simple
command** mid-body (a bare `[ … ]`, `[[ … ]]`, `(( … ))`, a plain
command, or a failing pipeline) **does abort the test** — verified
empirically. So the "unguarded assertion silently passes" story is
*not* true for plain assertions here.

What Bash *does* exempt from errexit (these genuinely don't fail the
test, on any version):

- any command used as an `if`/`while`/`until` **condition**;
- the **left** side of `&&` / `||` (and any non-final command in such a
  list);
- a **negated** command (`! cmd`) — but see §1c: bats's own
  preprocessor breaks bare `!` in a different way.

([gotchas], [writing-tests], verified locally on Bats 1.11.1 / Bash 5.2)

> Why guards still matter. The `|| return 1` / `|| fail` idiom is *not*
> needed for correctness of a plain `[ … ]` on this toolchain — errexit
> already aborts. It is still worth requiring for two reasons: (1) it
> makes the assertion robust if the suite is ever run on old Bash 3.2
> (macOS) where `[[ … ]]`/`(( … ))` are exempt unless last; (2) paired
> with `fail "…"` it prints *which* assertion failed. Treat unguarded
> plain `[ … ]` as a **style** issue, not a correctness bug — the
> exempt forms in §1b/§1c are where real masking happens.

### 1a. A bare `[ … ]` aborts on 1.11.1 — but guard it anyway

❌ **Unguarded** — correct on 1.11.1, but fragile and silent about
which line failed:

```bash
@test "parses config" {
  run parse_config fixture.cfg
  [ "$status" -eq 0 ]          # aborts here on 1.11.1 if false...
  [ "$output" = "ok" ]         # ...but no message saying which failed
}
```

On Bash 3.2 a non-final `[[ … ]]`/`(( … ))` here would *not* abort, and
the verdict would fall to the last command only — the classic mask.

✅ **Right** — make each assertion's failure propagate *and* self-document.
Pick ONE idiom and use it consistently:

```bash
@test "parses config" {
  run parse_config fixture.cfg
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "ok" ] || return 1
}
```

> Be consistent: a suite that mixes guarded and unguarded assertions is
> a yellow flag (signals the author wasn't sure which abort).

### 1b. `[[ … ]]` and `(( … ))` are errexit-exempt on Bash < 4.1

The errexit handling of `[[ … ]]` and `(( … ))` changed in Bash 4.1.
On older Bash (notably **macOS's stock 3.2**), a non-final `[[ … ]]` or
`(( … ))` does **not** abort the test. On the Bash 5.2 in this repo
they *do* abort (verified). Guarding makes the test portable to 3.2.
([gotchas])

❌ `[[ "$output" == *ok* ]]` mid-body — silent pass on Bash 3.2.
✅ `[[ "$output" == *ok* ]] || return 1` — or prefer `[ … ]` / `grep -q`.

### 1c. Bare `! cmd` is broken in a bats body — use `run ! cmd`

Two things go wrong, so never write a bare `! cmd` in a `@test`:

1. Bash exempts a negated command from errexit, so on a permissive
   shell `! grep -q bad <<<"$output"` mid-body wouldn't fail the test.
2. More importantly, **bats's preprocessor mangles a line whose first
   token is `!`** — it runs `!` as a literal command, which fails with
   `!: command not found` (status 127). Verified on 1.11.1: every bare
   `! cmd` form, including the gotchas-page fallback `! cmd || false`,
   blows up with 127 regardless of whether `cmd` passed.

❌ `! some_command`  ❌ `! some_command || false`  ❌ `[[ … ]] && ! …`
✅ `run ! some_command` (Bats ≥1.5; declare `bats_require_minimum_version
   1.5.0` to silence the BW02 warning).
✅ Without `run`: `some_command && return 1 || true` (the `return 1`
   fires only if `some_command` *succeeds*; verified). This avoids the
   leading-`!` mangling entirely.

### 1d. An optional `fail` helper

bats-core has no built-in `fail`, but the idiom is one line. Define it
in your shared helper and use it for readable messages:

```bash
fail() { printf '%s\n' "$1" >&2; return 1; }

@test "exit code is 0" {
  run my_cmd
  [ "$status" -eq 0 ] || fail "expected 0, got $status: $output"
}
```

`fail` returning non-zero as the body's last-executed command reliably
fails the test and prints context to stderr (shown on failure).

---

## 2. `run` usage

`run CMD` invokes `CMD`, captures exit status into `$status` and
combined stdout+stderr into `$output` (and `$lines`), then **returns 0
itself** so you can keep asserting. ([writing-tests]) Because `run`
masks the real exit, you MUST assert `$status` explicitly — `run` by
itself proves nothing.

### 2a. When NOT to use `run`

If you only need "did it succeed?", call the command **directly** —
errexit fails the test on non-zero. `run -0 cmd args` is equivalent to
plain `cmd args` but noisier. ([writing-tests])

✅ `make_dir "$BATS_TEST_TMPDIR/x"`        # fails test if non-zero
❌ `run make_dir …; [ "$status" -eq 0 ]`   # only when you need $output too

Use `run` when you need to inspect `$output`/`$lines`/`$stderr`, OR
when you expect a **non-zero** exit (so errexit doesn't abort first).

### 2b. The `run -N` and `run !` exit-code forms (assert status inline)

```bash
run -0 cmd …      # expect EXACTLY exit 0; fail otherwise
run -1 cmd …      # expect EXACTLY exit 1 (N is 0-255, matched exactly)
run ! cmd …       # expect ANY nonzero (1-255); fail if it succeeds
```

`run ! cmd` (Bats ≥1.5) is the correct way to assert "this must fail":
bare `! cmd` mid-body is both errexit-exempt and mangled by the bats
preprocessor (§1c). ([writing-tests])

> BW02: using any flag on `run` (`run -0`, `run !`, `run -127`, …)
> emits BW02 unless you declare `bats_require_minimum_version 1.5.0`,
> since flags were added in 1.5. Verified on 1.11.1: the warning fires
> per call without the floor and is silenced by it.

> BW01: `run` flags exit code 127 ("command not found") as a likely
> masked typo. If 127 is genuinely expected, write `run -127 cmd` to
> acknowledge it; if it should merely be nonzero, `run ! cmd`. ([BW01])

### 2c. Asserting on `$output` / `$lines` without helper libs

```bash
[ "$output" = "exact match" ]                 # exact
[[ "$output" == *needle* ]] || return 1       # substring (guard it!)
grep -q 'pattern' <<<"$output"                # regex/glob via grep
printf '%s\n' "$output" | grep -qE 'a|b'      # alternation
[ "${#lines[@]}" -eq 3 ]                       # line count
[ "${lines[0]}" = "first line" ]              # specific line
[ "${lines[-1]}" = "last line" ]             # last line
```

Always **quote** `"$output"` — unquoted it word-splits and globs.

### 2d. `--separate-stderr` and `--keep-empty-lines`

By default `$output` is **combined** stdout+stderr, and empty lines are
dropped from `$lines`. ([writing-tests])

```bash
run --separate-stderr cmd …
[ "$output" = "on stdout" ] || return 1       # $output = stdout only
[ "$stderr" = "on stderr" ] || return 1       # $stderr / $stderr_lines populated

run --keep-empty-lines cmd …
[ "${#lines[@]}" -eq 5 ]                       # blank lines counted
```

Combine as `run --separate-stderr --keep-empty-lines …`. These are
`run` flags, so they too emit BW02 unless `bats_require_minimum_version
1.5.0` is declared (verified).

### 2e. Pipes: `run cmd | jq` does NOT work

Bash parses `|` *outside* `run`, so `run echo foo | grep bar` runs
`(run echo foo) | grep bar` and `run`'s captured output is empty.
([gotchas]) Use one of:

```bash
run bash -c 'echo foo | grep bar'            # wrap in a shell
run bats_pipe echo foo \| grep bar           # bats ≥1.10, escape the pipe
```

`bats_pipe` propagates exit status like `set -o pipefail` by default
(`-N` / `--returned-status N` pick a specific stage, negatives count
from the end). It was added in Bats 1.10.0 (documented in 1.11.1), so
it is available here; declare `bats_require_minimum_version 1.10.0` if
you rely on it. ([writing-tests])

---

## 3. setup/teardown and isolation

### 3a. Per-test vs per-file

- `setup()` / `teardown()` run **before/after each** `@test`.
- `setup_file()` / `teardown_file()` run **once** before the first
  test's setup / after the last test's teardown in the file. Variables
  `export`ed in `setup_file` are visible to all tests. ([writing-tests])

Put cheap, per-test fixtures in `setup`; put expensive, read-only,
shared setup (compile a binary once, start a server) in `setup_file`.

### 3b. Use the provided tmpdirs — never hand-roll `mktemp`+`trap`

Bats creates and auto-cleans these; do not reinvent them:

- `$BATS_TEST_TMPDIR` — unique per test. ([writing-tests])
- `$BATS_FILE_TMPDIR` — shared by all tests in the file.
- `$BATS_SUITE_TMPDIR` — shared by every test in the whole suite
  (across files); use for a fixture built once per `bats` invocation.
- `$BATS_TEST_DIRNAME` — directory of the `.bats` file (for locating
  fixtures and the script under test). Not a tmpdir; do not write to it.

(`$BATS_RUN_TMPDIR` exists too but is bats's internal scratch — leave
it alone.)

❌ `tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT`
✅ `out="$BATS_TEST_TMPDIR/out.txt"` — cleaned automatically.

### 3c. Each `@test` runs in its own subshell

Tests don't share mutable state — a variable set in test A is invisible
in test B, and `run`'s subshell means side effects inside `run` don't
persist to the test body either ([gotchas]). Never rely on one test's
mutations leaking into another. Share **read-only** setup via `setup`/
`setup_file` exports, not via cross-test ordering.

### 3d. teardown can fail a test

A non-zero return from `teardown`/`teardown_file` fails the test.
Inside `teardown` errexit is disabled, so guard intentional cleanup
failures and end with a success (`rm -f … || true`). ([writing-tests])

---

## 4. Naming, organization, tags, filtering

- One test file per unit/suite (`foo.bats` tests `foo.sh`). Keep files
  focused; co-locate under `tests/`.
- Test names are full sentences describing behavior:
  `@test "rejects an empty config file" { … }`.
- **Tags** via comment directives ([writing-tests]):

```bash
# bats file_tags=slow            # applies to every test below in file
# bats test_tags=net, integration   # applies only to the NEXT @test
@test "fetches remote index" { … }
```

  Tags: alphanumeric + `_ - :`, no whitespace; `bats:`-prefixed tags are
  reserved. `bats:focus` runs only focused tests **and forces exit 1**
  so a committed focus tag can't silently shrink CI.

- **Filtering**:
  - `bats -f 'regex' tests/` — run tests whose name matches.
  - `bats --filter-tags net,integration tests/` — AND of tags;
    `!tag` negates; repeat the flag for OR.
  - `bats --filter-status failed tests/` — rerun last run's failures.

---

## 5. Sourcing scripts and helpers (`load`, `bats_load_library`, paths)

- `load name` sources a file relative to the test file (or an absolute
  path). For backwards compatibility it first tries `name.bash`, then
  `name`; that `.bash`-extension fallback is **deprecated** — pass an
  exact filename. ([writing-tests]) `load` exits bats on failure; use
  `bats_load_safe` if you need to `load` conditionally. To source a
  `.sh` script-under-test, `source` it directly (more explicit than
  relying on `load`'s search):

```bash
setup() {
  source "$BATS_TEST_DIRNAME/../scripts/foo.sh"   # script under test
}
```

- `bats_load_library name` is for **system-installed** libraries
  resolved via `$BATS_LIB_PATH` (e.g. brew/npm installs) — not for
  in-repo helpers. Since this project has **no** helper libs, you
  should see `load`/`source`, not `bats_load_library`. ([writing-tests])
- Always build paths from `$BATS_TEST_DIRNAME`, never from `$PWD` or a
  relative path (cwd is not guaranteed).

---

## 6. Version pinning, skipping, retries

- Declare the floor once, near the top (or in `setup`):

```bash
bats_require_minimum_version 1.5.0
```

  This documents intent and silences the BW02 warning that any `run`
  flag (`run !`, `run -N`) emits otherwise. `run` flags need ≥1.5.0;
  `bats_pipe` ≥1.10.0; tag directives ≥1.8.0 (but tags are a comment
  directive and work without the floor — the floor is for the runtime
  features, not tags). `bats_require_minimum_version` *itself* was
  introduced in 1.7.0, so it is a no-op floor below that. ([writing-tests])

- `skip "reason"` skips from that point on; conditional skips read well:

```bash
@test "needs docker" {
  command -v docker >/dev/null || skip "docker not installed"
  run docker info
  [ "$status" -eq 0 ] || return 1
}
```

  `setup`/`teardown` still run for skipped tests. ([writing-tests])

- `BATS_TEST_RETRIES=N` retries a failing test up to N times. Treat
  retries as a **smell** — they hide flaky tests. The default 0 (must
  pass first try) is correct for a deterministic suite; a reviewer
  should question any nonzero value and demand a justification.
  ([writing-tests])

---

## 7. ShellCheck on `.bats` files

ShellCheck understands bats's non-standard `@test "…" { }` syntax
natively as of **ShellCheck 0.7** (per the bats-core gotchas page);
this repo lints with **0.10.0**, which parses `.bats` files directly —
no `shellcheck.sh` wrapper, no `--shell=bats` flag. Pass `.bats` files
straight to `shellcheck` (the precommit does exactly this:
`shellcheck -x scripts/*.sh tests/*.sh tests/*.bats`). Verified on
0.10.0: `@test` blocks are analyzed and real issues (SC2086, SC2155,
…) are reported inside the body.

- ShellCheck 0.10.0 is bats-aware enough that it does **not** fire
  SC2154 for `$status`/`$output`/`$lines`/`$stderr` (verified). If a
  `$BATS_*` var or a bats-injected var ever does trip SC2154, suppress
  narrowly, not globally:

```bash
# shellcheck disable=SC2154   # set by bats `run` / harness
```

- For a sourced helper or script-under-test, add a source directive so
  `shellcheck -x` follows it:

```bash
# shellcheck source=tests/helpers.bash
load helpers
```

- Keep `.bats` files lint-clean under the same `shellcheck` invocation
  the project uses for its `.sh` scripts; wire it into the precommit
  lint step.

---

## 8. Mocking, parameterization, and diagnostics

### 8a. Mock commands by shadowing them on `PATH`

The portable, bare-bats way to stub an external command (no mocking
library) is a fake executable earlier on `PATH`:

```bash
setup() {
  STUBDIR="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUBDIR"
}

@test "uses git, but git is stubbed" {
  cat > "$STUBDIR/git" <<'STUB'
#!/usr/bin/env bash
echo "stub git $*"
STUB
  chmod +x "$STUBDIR/git"
  run env PATH="$STUBDIR:$PATH" my_script
  [ "$status" -eq 0 ] || return 1
}
```

This is exactly the pattern `rename-test.bats` uses to stub `tmux`
(a per-test `$STUBDIR` script that logs `send-keys` and emits scripted
`capture-pane` output). Reviewer expectations for a PATH stub: it lives
under a bats tmpdir (auto-cleaned), it is `chmod +x`, and it is put on
`PATH` only for the call under test (`run env PATH=… cmd`) so it can't
leak into other tests. Prefer this over rewriting the script under test
to inject a command path.

### 8b. Parameterized cases — bats has no native loop-over-`@test`

Bats cannot register a `@test` from a `for` loop, and `.bats` files
take no parameters; the supported workaround is to drive cases through
environment variables, or to factor the assertion into a helper that
each `@test` calls with its own inputs. (Bats 1.11.0 added
`bats_test_function` for programmatic registration, but that is an
advanced, rarely-needed escape hatch — keep one explicit `@test` per
case for readable TAP output unless the case count is large.)
([writing-tests], [faq])

### 8c. Skipping and diagnostics flags worth knowing

- `skip "reason"` always carries a reason; `setup`/`teardown` still run
  for skipped tests. (There is no `BATS_RUN_SKIPPED` override in 1.11.1
  — verified absent from the install; to exercise a skipped body,
  comment the `skip` line.)
- `--print-output-on-failure` prints `$output` for failing tests (the
  single most useful CI flag — `run` hides output by default). Pair
  with `fail "…"` messages (§1d).
- `--show-output-of-passing-tests` and `--verbose-run` surface output
  more aggressively while debugging; `-x`/`--trace` is `set -x` for the
  test body.
- `-f 'regex'` runs one test (or a name subset); `--filter-status
  failed` reruns just last run's failures/missing tests (valid values:
  `failed`, `missed`). `--no-tempdir-cleanup` keeps the bats tmpdirs so
  you can inspect a failure. ([usage])

---

## 9. Common anti-patterns (reject on sight)

| ❌ Anti-pattern | ✅ Fix |
|---|---|
| Checking `$?` after `run` | `run` returns 0; assert `$status`. |
| Mixing guarded and unguarded `[ … ]` mid-body | Pick one idiom; guard with `\|\| return 1` / `\|\| fail` for self-documenting failures and Bash-3.2 portability. (Plain `[ … ]` does abort on 1.11.1 — this is style, not a silent-pass bug.) |
| Bare `[[ … ]]` / `(( … ))` mid-body where 3.2 portability matters | Guard, or use `[ … ]` / `grep -q`. |
| Unquoted `$output` (`[ $output = x ]`) | Always `"$output"`. |
| Bare `! cmd` to assert failure | `run ! cmd` (Bats ≥1.5) — a leading `!` is mangled by the bats preprocessor (status 127). |
| `run cmd \| grep …` expecting a pipe | `run bash -c '…'` or `run bats_pipe`. |
| Relying on test execution order / shared mutable state | Each test is an isolated subshell; use `setup`. |
| Logic-under-test defined inside the `.bats` file | Source the real script; test the artifact. |
| `run` when a direct call is clearer | Direct call for pure success checks. |
| Swallowing stderr (combined `$output` hides it) | `--separate-stderr` when stderr matters. |
| Hand-rolled `mktemp`+`trap` cleanup | `$BATS_TEST_TMPDIR` / `$BATS_FILE_TMPDIR`. |
| `bats_load_library` for in-repo helpers | `load` / `source` with `$BATS_TEST_DIRNAME`. |
| `BATS_TEST_RETRIES` masking flakiness | Fix the test; default is 0. |

---

## Reviewer checklist

Run down these binary, checkable items against the converted suite:

- [ ] **Assertions are consistently guarded.** Each non-final `[ … ]`,
      `[[ … ]]`, `(( … ))` is terminated with `|| return 1` /
      `|| fail "…"` (or is a direct command relying on errexit). On
      1.11.1 a plain `[ … ]` aborts unguarded, so this is a
      style/portability/diagnostics standard, not a silent-pass bug —
      but a suite that *mixes* guarded and unguarded is a flag. The
      genuinely-exempt forms (`if`/`while` conditions, `&&`/`||` LHS,
      leading `!`) must never carry the sole assertion.
- [ ] **`$status` is asserted after every `run`.** No test calls `run`
      and then only inspects `$output` without checking `$status` (or
      uses the `run -N` / `run !` form).
- [ ] **No `$?` after `run`.** Status is read via `$status` only.
- [ ] **`$output` is always double-quoted** in every assertion.
- [ ] **Failure is asserted via `run ! cmd`**, never a line beginning
      with bare `! cmd` (the bats preprocessor mangles a leading `!` to
      a 127 "command not found").
- [ ] **No `run cmd | …` pipelines.** Pipes are wrapped in
      `run bash -c '…'` or `run bats_pipe … \| …`.
- [ ] **`run` is used only when needed** (output inspection or expected
      non-zero exit); pure success checks call the command directly.
- [ ] **stderr is not silently swallowed** where it matters:
      `--separate-stderr` is used when asserting on stderr.
- [ ] **`--keep-empty-lines`** is used wherever empty lines are
      significant to a `$lines` count.
- [ ] **No hand-rolled `mktemp`+`trap`**; tests use
      `$BATS_TEST_TMPDIR` / `$BATS_FILE_TMPDIR`.
- [ ] **Paths derive from `$BATS_TEST_DIRNAME`**, not `$PWD` or bare
      relative paths.
- [ ] **The script under test is `source`d / `load`ed**, not
      reimplemented inside the `.bats` file.
- [ ] **No reliance on test order or cross-test mutable state**; shared
      read-only setup lives in `setup`/`setup_file`.
- [ ] **Expensive shared setup is in `setup_file`**, per-test fixtures in
      `setup`.
- [ ] **`teardown` ends successfully** (`… || true`) and doesn't
      accidentally fail tests.
- [ ] **Test names are descriptive sentences**, one focused `.bats` file
      per unit.
- [ ] **Tags use the `# bats test_tags=` / `file_tags=` directive
      syntax** correctly (no whitespace, valid chars); no stray
      `bats:focus` committed.
- [ ] **`bats_require_minimum_version`** is declared if any `run` flag
      (`run !`, `run -N`) or `bats_pipe` is used (silences BW02); tags
      work without it.
- [ ] **PATH stubs are hygienic.** A mocked command lives under a bats
      tmpdir, is `chmod +x`, and is on `PATH` only for the call under
      test (`run env PATH="$STUBDIR:$PATH" …`), so it can't leak across
      tests.
- [ ] **No native loop-over-`@test`.** Parameterized cases are driven by
      env vars or a shared helper, not by an unsupported `for`-loop
      around `@test`.
- [ ] **`bats_load_library` is NOT used for in-repo helpers** (this
      project has no installed libs); `load`/`source` are used instead.
- [ ] **No `assert_output`/`assert_success`/`assert_file_*`** or other
      helper-library calls — the suite is bare bats-core.
- [ ] **`BATS_TEST_RETRIES` is 0** (unset) unless a documented
      justification exists.
- [ ] **`.bats` files pass `shellcheck`** under the project's lint
      invocation; SC2154 suppressions are narrow and source directives
      present for sourced helpers.
- [ ] **`skip "reason"` carries a reason**; conditional skips guard
      genuinely unavailable dependencies, not flaky logic.

---

### Sources

Docs fetched and version requirements cross-checked 2026-06-08
against the `en/stable` docs (which track 1.11.x):

- [writing-tests]: bats-core — Writing tests:
  https://bats-core.readthedocs.io/en/stable/writing-tests.html
  (run -N/!, --separate-stderr/--keep-empty-lines, bats_pipe, tmpdir
  vars incl. $BATS_SUITE_TMPDIR, tags 1.8.0, bats:focus, load vs
  bats_load_safe, BATS_TEST_RETRIES, bats_require_minimum_version 1.7.0)
- [gotchas]: bats-core — Gotchas:
  https://bats-core.readthedocs.io/en/stable/gotchas.html
  (errexit `[[ ]]`/`(( ))` change at Bash 4.1; `! cmd` exemption + the
  `! x || false` fallback; `run cmd | …` parsing; ShellCheck native
  bats support "as of 0.7")
- [usage]: bats-core — Usage:
  https://bats-core.readthedocs.io/en/stable/usage.html
  (--filter-status values `failed`/`missed`, --print-output-on-failure,
  --show-output-of-passing-tests, --verbose-run, -x, -j, -f)
- [faq]: bats-core — FAQ (no loop-over-`@test`; parameterize via env)
- [BW01]: https://bats-core.readthedocs.io/en/stable/warnings/BW01.html
  (run exit 127 → likely masked typo; acknowledge with `run -127`/`run !`)
- ShellCheck native `.bats` support: stated "as of 0.7" on the gotchas
  page; bats-core `shellcheck.sh`
  https://github.com/bats-core/bats-core/blob/master/shellcheck.sh

Empirically verified locally (Bats **1.11.1**, Bash **5.2.37**,
ShellCheck **0.10.0**), 2026-06-08:

- Plain `[ … ]`, `[[ … ]]`, `(( … ))`, and failing pipelines **abort**
  the test mid-body under errexit; `if`/`while` conditions and `&&`/`||`
  LHS **silently pass**.
- A `@test` body line beginning with `!` is mangled to a literal `!`
  command (status 127, "command not found") — so bare `! cmd` and
  `! cmd || false` both fail with 127; `run ! cmd` and
  `cmd && return 1 || true` are the working forms.
- Any `run` flag emits **BW02** without `bats_require_minimum_version`;
  the floor silences it. `bats_pipe` added in 1.10.0.
- ShellCheck 0.10.0 lints `.bats` directly (no wrapper), analyzes
  `@test` bodies (SC2086/SC2155 fire), and does **not** raise SC2154
  for `$status`/`$output`/`$lines`/`$stderr`.
- `BATS_RUN_SKIPPED` is **absent** from the 1.11.1 install (only the
  internal `BATS_TEST_SKIPPED` exists).
