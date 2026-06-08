# pytest best practices — reviewer rubric (handoff repo)

This is the rubric a reviewer uses to audit pytest suites **in this repo**.
It is not a tutorial; it is opinionated and checkable. The subject under
test is `scripts/extract.py` (a stdlib-only CLI script — **not** an
installed package), tested by `tests/test_extract.py` against JSONL fixtures
in `tests/fixtures/`. The suite runs as a bare `pytest` off a
direnv-activated uv venv (config in `pyproject.toml`; see §10) — there is no
`conftest.py`.

Every section ends with concrete ✅/❌ examples written in this repo's
idioms. The **Reviewer checklist** at the bottom is the primary
deliverable — run it down against the module under review.

All API claims below were verified on 2026-06-08 against the official
pytest docs and empirically against the pinned toolchain in this repo —
**pytest 9.0.3 on Python 3.14.3** (`.venv/bin/pytest --version`). Sources:
import modes / `pythonpath`
([pythonpath.html](https://docs.pytest.org/en/stable/explanation/pythonpath.html),
[goodpractices.html](https://docs.pytest.org/en/stable/explanation/goodpractices.html)),
`tmp_path` / `tmp_path_factory`
([tmp_path.html](https://docs.pytest.org/en/stable/how-to/tmp_path.html)),
parametrize
([parametrize.html](https://docs.pytest.org/en/stable/how-to/parametrize.html)),
capture
([capture-stdout-stderr.html](https://docs.pytest.org/en/stable/how-to/capture-stdout-stderr.html)),
markers
([mark.html](https://docs.pytest.org/en/stable/how-to/mark.html)),
config
([customize.html](https://docs.pytest.org/en/stable/reference/customize.html)),
strictness options
([changelog 9.0.0](https://docs.pytest.org/en/stable/changelog.html)).

**pytest 8 → 9 note (relevant to this rubric):** the default import mode
is still `prepend` — `importlib` was *not* promoted to default (the pytest
team decided it keeps its own drawbacks, so `prepend` stays the default
"for the foreseeable future"); this repo opts into `importlib` explicitly.
pytest 9.0 added a unified `strict` config option plus the `strict_markers`,
`strict_config`, `strict_xfail` (alias of `xfail_strict`) and
`strict_parametrization_ids` ini aliases — `--strict` now turns the whole
set on (see §8). pytest 9 also makes `PytestRemovedIn9Warning`
deprecations hard errors by default and dropped Python 3.9. None of these
break the suite as configured.

---

## 1. Importing a non-package module under test

`extract.py` lives in `scripts/` with no `__init__.py` and is not pip-installed.
`import extract` needs that directory on `sys.path`. There are two clean
ways; **prefer the ini option** in a `pyproject.toml`.

**Current state of this repo (resolved):** `pyproject.toml` carries the
pytest config, and `pythonpath = ["scripts"]` is the sole `sys.path`
mechanism. There is **no `conftest.py`** — an earlier `sys.path.insert`
bridge was deleted the moment the ini option landed. The config:

```toml
[tool.pytest.ini_options]
pythonpath = ["scripts"]          # the sole sys.path mechanism
testpaths = ["tests"]
addopts = ["--strict-markers", "--strict-config", "--import-mode=importlib"]
```

Keep exactly one `sys.path` mechanism: with `pythonpath` set, a
`conftest.py` `sys.path.insert` alongside it would be redundant — two
mechanisms doing one job is a review finding.

`pythonpath` paths are resolved **relative to the rootdir** (the dir
containing `pyproject.toml`) and prepended to the head of `sys.path` for the
whole session, so the import is stable regardless of where `pytest` is
invoked from — unlike a `__file__`-relative `sys.path.insert`, which works
but is more fragile.

A note on `--import-mode=importlib`: pytest recommends it **for new
projects** because it imports test modules without mutating `sys.path` (and
doesn't require unique test-module basenames). It is *not* pytest's default,
though — `prepend` remains the default mode in pytest 9; this repo opts into
`importlib` explicitly via `addopts`. The trade-off: in `importlib` mode the
tests directory is not added to `sys.path`, so test modules **cannot import
each other** and helper modules in the test dir are not importable. Verified
on pytest 9.0.3: with `pythonpath=["scripts"]` + `--import-mode=importlib`,
`import extract` resolves but `import some_sibling_test_helper` raises
`ModuleNotFoundError`. This repo keeps helpers as plain functions inside
`test_extract.py` (e.g. `render_frame`, `assert_order`, `write_task`) and
defines fixtures module- or class-locally in that one file, so `importlib`
mode is fine. (`pythonpath` itself is unaffected by the import mode — it
works under both.) If you ever add a `tests/helpers.py` imported by multiple
test modules, either switch to `prepend` mode or move the helper next to
application code (e.g. under `scripts/`, already on `pythonpath`).

✅ **the chosen approach:** `pythonpath = ["scripts"]` in `pyproject.toml`,
no `conftest.py` path hack.

✅ **conftest bridge (only if there were no pyproject — NOT used here, shown
for contrast):**
```python
# tests/conftest.py
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
```
Either mechanism is correct *only because* importing `extract` has **no side
effects** — its CLI is guarded by `if __name__ == "__main__":` and module
top-level is pure constants + function defs. Verify that guard exists before
trusting any import-based unit test.

❌ **per-test path munging:**
```python
def test_x():
    sys.path.insert(0, "../scripts")   # repeated, order-dependent, leaks state
    import extract
```

❌ Importing a module whose top level runs work (network, file writes, arg
parsing). If `import extract` did anything, the unit tests would be testing a
side effect, not a function. Reject modules that aren't import-safe.

---

## 2. Altitude of assertion (the core judgment)

The single most important review axis. Each test sits at one of two
altitudes; the wrong altitude is the most common defect.

**Unit (import the pure function, assert on its return value)** — use when
the behavior is a deterministic transform with a structured output:
`clamp_anchor_lines`, `format_quote`, `is_wrapper_entry`, `user_text`,
`extract_files_touched`, `anchor_for`. These are fast, give real diffs on
failure, and pin exact behavior.

**End-to-end / contract (render the full frame, or run the CLI)** — use when
the *guarantee* is about the assembled artifact or the `__main__` path: the
full rendered handoff frame, section ordering, the `Session:` line, the
inlining of `handoff-task.md`, the `usage`/exit-code contract of `main()`.
A unit test of one helper cannot stand in for "the whole frame renders
correctly."

### Decision rule
> Test at the **lowest altitude that still proves the guarantee you care
> about.** If the guarantee is "this function maps X→Y," unit-test the
> return value. If the guarantee is "the rendered frame / CLI contract holds
> end-to-end," you need a full-render or subprocess test — a unit check on a
> sub-function does **not** discharge it.

Two symmetric anti-patterns, both review findings:

❌ **Down-substitution** — replacing an end-to-end guarantee with a weaker
unit check. e.g. deleting the subprocess `main()` test and claiming
`test_emit_*` covers it. It doesn't: `main()` owns arg-count validation,
the `usage` message, and exit codes 0/2, none of which `emit()` exercises.

❌ **Up-substitution (grep-on-render)** — asserting on a *substring of the
rendered frame* when a clean return-value assertion exists at the function
level.
```python
# ❌ brittle: re-derives format_quote's behavior from rendered output
assert ">\n" in render_frame(transcript, task)
# ✅ precise: pin the function contract directly
assert extract.format_quote("a\n\nb") == ["> a", ">", "> b"]
```
Grep-on-render is justified **only** when the property is genuinely
cross-cutting (ordering of whole sections, "file1 appears before file2 in
the frame," "no `@handoff-task.md` ref anywhere"). Those can't be expressed
as a single function's return value, so the full render is the right altitude.

✅ This repo gets it right: `TestFormatQuote`/`TestClampAnchorLines`/etc. are
unit; `TestExtractBasic` (subprocess) and `TestSkillMeta`/`TestBounded`
(full `emit()` render) are end-to-end. Use that split as the template.

---

## 3. tmp_path / tmp_path_factory and render-once-assert-many

**Never** `tempfile.mkdtemp()` / hand-rolled cleanup. Use the builtin
fixtures: `tmp_path` (a `pathlib.Path`, **function-scoped**, auto-cleaned)
for per-test files; `tmp_path_factory` (**session-scoped**, `.mktemp("name")`)
when a fixture needs a temp dir at a wider scope.

✅ per-test task file:
```python
def write_task(tmp_path, body):
    p = tmp_path / "handoff-task.md"
    p.write_text(body)
    return p
```

❌ `d = tempfile.mkdtemp(); ... # who deletes this?` — leaks across runs,
no auto-cleanup, defeats isolation.

### Render-once, assert-many
When many assertions inspect one expensive artifact (a fully rendered
fixture frame), compute it **once** in a fixture and assert against the
result repeatedly. This repo does exactly that — `TestExtractBasic.out` is a
`scope="class"` fixture that runs the subprocess once; the ~15 `test_*`
methods each take `out` and assert one property:
```python
class TestExtractBasic:
    @pytest.fixture(scope="class")
    def out(self, tmp_path_factory):
        d = tmp_path_factory.mktemp("basic")
        ...
        return subprocess.run(...).stdout
    def test_header_present(self, out): assert "# Handoff — " in out
```
Note the scope coupling: a **`scope="class"`** fixture cannot depend on
**function-scoped** `tmp_path`, which is why `tmp_path_factory` is used here.
That is the correct pairing, not a workaround.

**Scope trade-off (state the rule):** widen scope (`class`/`module`/
`session`) **only** when the artifact is read-only and expensive to build.
The render fixtures here are safe because the output string is never mutated.
The moment a test would *write into* a shared dir or mutate shared state,
drop back to function scope — a shared mutable fixture creates inter-test
dependence (see §7). Reviewer heuristic: wide scope + immutable value = good;
wide scope + anything mutable = suspect.

---

## 4. parametrize for families of cases

Use `@pytest.mark.parametrize` for families of near-identical cases instead
of copy-pasted test bodies or loops-with-asserts. This repo uses it well for
wrapper-filter lists, per-line anchor checks, file lists, and dropped/kept
sentinels.

✅ table of cases, one assertion body:
```python
@pytest.mark.parametrize("text", [
    "<system-reminder>note</system-reminder>",
    "<bash-input>ls</bash-input>",
    "[Request interrupted by user]",
])
def test_wrappers_detected(self, text):
    assert extract.is_wrapper_entry(text) is True
```

❌ a `for` loop inside one test — a single failure aborts the rest and the
failure message doesn't say *which* input broke:
```python
def test_wrappers(self):
    for text in [...]:
        assert extract.is_wrapper_entry(text)   # which one failed?
```

**`ids=` for readable names** when the param value isn't self-describing
(multi-line strings, dicts, long paths):
```python
@pytest.mark.parametrize("lines,expected", CASES,
    ids=["below-limit", "at-limit", "above-limit-truncates"])
```
With short literal strings (like the wrapper list) the default ids are
already readable; don't add noise. Reviewer check: can you tell which case
failed from `pytest -v` output alone?

**`pytest.param(..., marks=...)`** to mark one row (e.g. a known-xfail or
slow case) without splitting the table:
```python
@pytest.mark.parametrize("expr,expected", [
    ("3+5", 8),
    pytest.param("6*9", 42, marks=pytest.mark.xfail(reason="known wrong")),
])
```

Don't over-parametrize: if two "cases" exercise different code paths with
different assertions, they are different tests — keep them separate.

---

## 5. Capturing output

**`capsys`** captures Python-level `sys.stdout`/`sys.stderr` and is the
natural choice for an in-process render — `emit()` writes via
`sys.stdout.write`. But `capsys` is **function-scoped**, so it cannot back a
`class`/`module`-scoped fixture. This repo renders the same fixture frame
across many assertions at `scope="class"` (render-once-assert-many, §3), so
it uses a single `contextlib.redirect_stdout(io.StringIO())` helper rather
than `capsys` — one render path that works at any scope:
```python
def render_frame(transcript_path, task_path):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        extract.emit("" if transcript_path is None else str(transcript_path),
                     str(task_path))
    return buf.getvalue()
```
That is a deliberate call, not a smell. If you *do* reach for `capsys` in a
function-scoped test, capture into a local immediately: `readouterr()`
returns a `(out, err)` named tuple **and consumes the buffer** (it resets on
each read), so a second `readouterr()` returns "". (Verified on pytest
9.0.3: after `print("first")`, the first `readouterr().out == "first\n"` and
the second `readouterr().out == ""`.)

**`capfd`** captures at the OS file-descriptor level — needed for output from
subprocesses or C libraries that bypass `sys.stdout`. Use it only when
`capsys` would miss the output.

### Subprocess end-to-end
To cover the real `__main__` path, run the script as a child process and
assert on `returncode` + `stdout`. Use `sys.executable` (the active
interpreter — never a bare `"python"`), absolute script path, and an explicit
`cwd`:
```python
result = subprocess.run(
    [sys.executable, str(EXTRACT_PY), str(FIXTURES / "extract-basic.jsonl"),
     str(task)],
    check=True, capture_output=True, text=True, cwd=REPO_ROOT,
)
assert result.returncode == 0
assert "Session: `extract-basic`" in result.stdout
```
Build paths from `Path(__file__).parent.parent` (as this repo does:
`REPO_ROOT`, `FIXTURES`, `EXTRACT_PY`) so tests pass regardless of invocation
cwd. The error-contract case must assert the exit code, not just stdout:
```python
r = subprocess.run([sys.executable, str(EXTRACT_PY)], capture_output=True, text=True)
assert r.returncode == 2
assert "usage:" in r.stderr
```
This repo covers exactly that exit-2 contract in `TestCliContract` (a
subprocess with no args, asserting `returncode == 2` and `usage:` in
stderr). When auditing a *different* suite, an uncovered `main()` exit
path is a legitimate gap to flag.

❌ `subprocess.run(["python", ...])` — wrong interpreter outside the venv.
❌ `capsys` left un-consumed and re-read expecting the same content (the second
`readouterr()` returns "").

---

## 6. Assertion style

Use plain `assert` — pytest's assertion rewriting gives rich diffs. Never
`unittest`-style `self.assertEqual`. Prefer **structured equality** over
substring arithmetic.

✅ whole-value equality (best diff, pins exact behavior):
```python
assert extract.clamp_anchor_lines(lines) == \
    ["L1", "L2", "L3", "[ 2 lines omitted ]", "L6", "L7", "L8"]
```

❌ brittle index arithmetic where structured equality reads clearer:
```python
out = extract.clamp_anchor_lines(lines)
assert out[3][2:9] == "2 lines"     # what is being verified? unclear, fragile
```

**Ordering assertions** must actually enforce order. The repo wraps this in a
small `assert_order(haystack, *needles)` helper that checks each needle is
present and strictly later than the previous one — clearer than a chain of
`.index()` comparisons when several items must appear in sequence:
```python
assert_order(out, "ANCHOR8_L3", "[ 2 lines omitted ]", "ANCHOR8_L6")
```
For a bare two-item check an inline `index` comparison with a message is also
fine: `assert a < b, "file1 must render before file2"`. Don't bother adding a
message on `==` comparisons — the rewritten diff already says everything.

When a check needs more than one line of derivation, extract a small,
**obviously-correct** helper (like `render_frame`/`assert_order`/`write_task`)
— but the helper must contain *no logic under test* (see §9).

---

## 7. Fixtures & conftest organization

- **`conftest.py`** holds fixtures shared across modules and lives at the
  scope they're needed; fixtures auto-discover (no import). This suite is a
  single test module with no cross-module sharing, so there is **no
  `conftest.py` at all** — every helper/fixture is module- or class-local in
  `test_extract.py`. Add a `conftest.py` only when a second module needs to
  share a fixture.
- **Place a fixture at its narrowest useful scope.** A fixture used by one
  class belongs in that class (`@pytest.fixture` on a method), not at module
  scope. The per-class `out` render fixtures (`TestSkillMeta.out`,
  `TestBounded.out`, `TestAnchorMultiline.out`) live on their classes because
  only that class needs them — correct.
- **Don't overuse fixtures.** A two-line setup inlined in the test is clearer
  than a fixture that hides it. Fixtures earn their keep when shared, expensive,
  or needing teardown.
- **No inter-test dependence / order reliance.** Tests must pass in any order
  and in isolation (`pytest path::test_name` alone). Shared mutable state across
  tests is a defect. Guard against accidental coupling with **`pytest-randomly`**
  (randomizes order each run; a suite that breaks under it has hidden ordering
  assumptions).

✅ class-scoped immutable render reused by many assertions (§3) — shared but
read-only, so no coupling.
❌ a module-scoped list that one test appends to and a later test reads.
❌ `test_b` that only passes because `test_a` ran first and left a file behind.

---

## 8. Markers, selection, xfail vs skip, error paths

- Register every custom marker and run with **`--strict-markers`** so a
  typo'd `@pytest.mark.slwo` errors instead of silently never matching.
  **`--strict-config`** is complementary but distinct: it turns the
  *unknown-ini-key warning* into a hard error, so a fat-fingered
  `[tool.pytest.ini_options]` key (e.g. `pythonpath` → `pythonpaht`) fails
  the run instead of being silently ignored. Verified on pytest 9.0.3: a
  bogus ini key under `--strict-config` aborts with
  `ERROR: Unknown config option: <key>`; without it, the same key only emits
  a `PytestConfigWarning`. This repo enables both in `addopts`:
  ```toml
  [tool.pytest.ini_options]
  addopts = ["--strict-markers", "--strict-config"]
  markers = ["slow: end-to-end subprocess tests"]
  ```
  **pytest 9** added a single `strict = true` ini option (and `--strict`
  flag) that turns on *all* strictness checks at once — `strict_markers`,
  `strict_config`, `strict_xfail` (alias of `xfail_strict`), and
  `strict_parametrization_ids` — and will pick up any future strictness
  option automatically. Listing `--strict-markers`/`--strict-config`
  individually (as this repo does) is still correct and explicit; `strict =
  true` is the broader-net alternative if you also want strict xfail and
  parametrize-id checking. Either is acceptable; don't flag the explicit
  pair as wrong.
- Select with `-k` (name substring) and `-m` (marker expr, e.g.
  `-m "not slow"`). If subprocess tests are ever marked `slow`, a fast inner
  loop becomes `pytest -m "not slow"`.
- **`xfail` vs `skip` — do not smuggle away coverage.** `skip` = "don't run
  this here" (platform/dependency gate). `xfail` = "this *should* pass but
  currently doesn't; keep running it so we learn when it starts passing"
  (use `strict=True` so an unexpected pass fails the suite). Neither is a
  place to park a test you broke. A test converted to `xfail`/`skip` to make
  CI green, with no genuine reason, is a review **reject** — that is deleting
  coverage in disguise.
- **`pytest.raises` for error paths** — assert the exception type, and pin
  the message with `match=` (a regex `re.search` over `str(exc)`) when the
  wording is part of the contract:
  ```python
  with pytest.raises(json.JSONDecodeError):
      ...
  with pytest.raises(ValueError, match=r"unexpected token"):
      ...
  ```
  Mind this repo's actual CLI shape: `extract.main(argv)` **returns an int
  (2)** on a wrong arg count and writes `usage:` to stderr — it does **not**
  raise `SystemExit` (only the `if __name__ == "__main__"` guard wraps it in
  `sys.exit`). So the in-process contract is a return-value assertion, not a
  `pytest.raises(SystemExit)`:
  ```python
  # in-process: main returns 2 (note a non-empty argv[0]; main([]) IndexErrors)
  assert extract.main(["extract.py"]) == 2
  ```
  The repo instead exercises this end-to-end through the `__main__` path
  (`TestCliContract`, a subprocess asserting `returncode == 2` and `usage:`
  in stderr), which is the stronger altitude (§2) — that contract is
  covered, not a gap. Don't wrap an error path in `try/except: pass` — that
  asserts nothing.

---

## 9. Anti-patterns (auto-reject list)

- **Logic-under-test in the test file.** If the test re-implements
  `clamp_anchor_lines`'s slicing to compute its own "expected," a bug in the
  real function is mirrored in the test and never caught. Expected values must
  be **literals or trivially-correct constants**, not re-derivations.
- **`assert True` / tautologies** (`assert x == x`, `assert out is not None`
  after assigning a string). Asserts nothing.
- **Over-mocking.** `extract.py` is pure stdlib over in-memory data and real
  fixture files — there is nothing to mock. Introducing `unittest.mock` to
  stub `pathlib`/`json` here is a smell; use a real `tmp_path` file or a
  fixture JSONL instead. Note `extract.main(argv)` takes `argv` as a
  **parameter** (it does not read `sys.argv`), and `emit(transcript, task)`
  takes explicit paths — so a unit test passes inputs directly with **no
  `monkeypatch`** of `sys.argv`/`os.environ`/`os.chdir` needed. If a future
  function read `sys.argv` or the cwd directly, `monkeypatch.setattr` /
  `monkeypatch.chdir(tmp_path)` would be the right seam — still prefer that
  over `unittest.mock`.
- **Asserting on incidental formatting.** Pinning exact whitespace/byte counts
  of the whole frame when the behavior under test is one section makes every
  cosmetic edit a test failure. Assert the property you care about at its
  altitude (§2).
- **Catch-and-ignore.** `try: assert ... except: pass` and bare `except:`
  swallow real failures.
- **Testing private helpers when the public contract suffices.** `extract.py`
  exposes a flat module of functions — test the ones whose behavior is a real
  guarantee (`format_quote`, `anchor_for`, …). Don't add tests pinning an
  internal like `_is_handoff_write` *in addition to* the `TestBounded`
  end-to-end test that already proves the boundary behavior, unless the unit
  test buys a distinct, sharper guarantee. (Here `_is_handoff_write` is
  legitimately covered *through* `TestBounded` — that's the public contract.)
- **Slow, unfocused fixtures.** A `session`-scoped fixture that builds
  everything for tests that need a slice of it. Build the minimum; widen scope
  only for genuinely expensive, immutable artifacts.

---

## 10. Reproducible runs: pinned deps via a direnv-activated venv

`pytest` is the only dependency (in a `dev` group), pinned in a committed
`uv.lock`. The venv is materialized once with **`uv sync`** — the only `uv`
invocation. The suite then runs as a **bare `pytest`**: `.envrc` exports
`VIRTUAL_ENV=$PWD/.venv` and prepends `$VIRTUAL_ENV/bin` to `PATH`, so
**direnv** activation puts the locked `pytest` on `PATH`.

This project deliberately avoids `uv run` under Claude Code: every `uv run`
touches `~/.cache/uv`, which the agent sandbox blocks — `uv sync` once +
direnv sidesteps that, and no test/precommit step needs a sandbox bypass.
Refresh the lock with `uv sync` when deps change; commit `uv.lock`.

Any pytest configuration (`pythonpath`, `testpaths`, `addopts`, `markers`)
lives in **`pyproject.toml` `[tool.pytest.ini_options]`** — one source of
truth, discovered via rootdir. Don't scatter config into a separate
`pytest.ini` *and* `pyproject.toml`; pick the `pyproject.toml` table.

Reviewer note: keep exactly one `sys.path` mechanism — `pyproject.toml`'s
`pythonpath = ["scripts"]` is it; a `conftest.py` `sys.path.insert` alongside
it would be redundant (flag it).

---

## 11. Warnings-as-errors and dev-loop hygiene

- **Treat warnings as errors.** `filterwarnings = ["error"]` in
  `[tool.pytest.ini_options]` makes any unhandled warning fail the run, so a
  `DeprecationWarning` from a stdlib call (or a future dep) surfaces as a
  test failure instead of scrolling past. pytest 9 already raises its own
  `PytestRemovedIn9Warning` deprecations as errors by default; adding
  `error` extends that to *all* warnings the suite triggers. When a warning
  is genuinely expected, scope it: assert it with `pytest.warns(...)` or
  `recwarn`, or add a narrow `ignore::...` entry rather than dropping the
  global `error`. This repo doesn't set `filterwarnings` yet — a reasonable,
  low-cost hardening to recommend, not a defect to reject.
- **Dev-loop flags** (not config — invocation-time, worth knowing for the
  reviewer's own runs): `-x` (stop at first failure), `--lf` (rerun only
  last-failed), `--ff` (failures first), `-k EXPR` (name filter), and
  `--durations=N` (surface the slowest N tests — here the subprocess/render
  fixtures, useful for spotting an accidentally-expensive fixture). None
  belong in committed `addopts`; they're for the inner loop.
- **Order independence is checkable.** `-p no:randomly` disables
  randomization when `pytest-randomly` is installed; conversely, running
  with it *on* (the default once installed) is the cheap way to flush out
  hidden inter-test ordering assumptions (§7). This suite has no such plugin
  pinned, so order-independence rests on the no-shared-mutable-state
  discipline in §7 — verify that by reading, or by `pytest --randomly-seed`
  if the plugin is added.

---

## Reviewer checklist

Binary, checkable items. Run down this list against the pytest module under
review; each should be answerable yes/no by reading the code.

**Import & config**
- [ ] The module under test imports cleanly with no side effects (CLI behind
      `if __name__ == "__main__":`); the import is not in a `try` or inside a
      test body.
- [ ] `sys.path` is manipulated in exactly **one** place (conftest *or*
      `pythonpath` ini) — not both, not per-test.
- [ ] If `pyproject.toml` exists, pytest config is in
      `[tool.pytest.ini_options]` (`pythonpath`, `testpaths`, `addopts`,
      `markers`) — not duplicated in a separate `pytest.ini`.
- [ ] `--strict-markers` is enabled (unregistered markers error) and every
      custom marker is registered; `--strict-config` is enabled (unknown ini
      keys error). pytest 9's `strict = true` umbrella is an acceptable
      substitute that also turns on strict xfail + parametrize-ids.

**Altitude (§2 — the core check)**
- [ ] Each test is at the lowest altitude that proves its guarantee.
- [ ] Pure-function behaviors are unit-tested on **return values**, not via
      grep on a rendered frame.
- [ ] Whole-frame / `__main__` / CLI guarantees have a **full-render or
      subprocess** test — not a sub-function unit check standing in for them.
- [ ] The CLI exit-code/`usage` contract (wrong arg count → exit 2 + `usage:`
      on stderr; in-process `main(["prog"]) == 2` or subprocess
      `returncode == 2`) is actually exercised somewhere, or the gap is
      explicitly acknowledged.

**Fixtures & isolation**
- [ ] Temp files use `tmp_path` / `tmp_path_factory`, never `tempfile.mkdtemp`
      or hand-rolled cleanup.
- [ ] Expensive artifacts are rendered **once** (render-once-assert-many) at an
      appropriate scope.
- [ ] Every widened-scope (`class`/`module`/`session`) fixture returns an
      **immutable** value or read-only resource; no test mutates shared state.
- [ ] Fixture scopes are compatible (no `class`-scoped fixture depending on
      function-scoped `tmp_path`/`capsys`).
- [ ] Tests pass in isolation and in any order; no test relies on another
      having run first (sanity-check with `pytest-randomly` if available).

**Parametrize & assertions**
- [ ] Families of similar cases use `@pytest.mark.parametrize`, not copy-paste
      or `for`-loops-with-asserts.
- [ ] Parametrized cases are individually identifiable in `-v` output (clear
      param values or `ids=`).
- [ ] Assertions use plain `assert` with structured equality where possible;
      no brittle string-index arithmetic where a clean `==` reads better.
- [ ] Order-dependent assertions enforce order explicitly (`index(...) <
      index(...)`), with a message where failure isn't self-evident.

**Output capture**
- [ ] In-process stdout is captured at a scope-appropriate mechanism —
      `capsys` for function-scoped tests, `contextlib.redirect_stdout` for
      `class`/`module`-scoped render fixtures (`capsys` is function-scoped and
      must not be requested from a wider-scoped fixture). Any `capsys`
      `readouterr()` is consumed once into a local.
- [ ] Subprocess tests use `sys.executable`, absolute script path, explicit
      `cwd`, and assert on **`returncode` + stdout/stderr**.

**Error paths & markers**
- [ ] Error/exception paths use `pytest.raises` (asserting type, and message
      via `match=` when it matters), never `try/except: pass`. A function that
      *returns* an error code (like `extract.main` → 2) is asserted on the
      return value, not `pytest.raises(SystemExit)`.
- [ ] No test is `skip`/`xfail`-ed to hide a real failure; `xfail` uses a
      genuine `reason` and `strict=True` where applicable.
- [ ] (Recommended) Warnings are not silently swallowed — `filterwarnings =
      ["error"]` or an explicit `pytest.warns`/`recwarn` for the expected
      ones; absence is a hardening gap, not a hard reject.

**Anti-patterns (any one = reject)**
- [ ] No logic-under-test re-implemented in the test (expected values are
      literals, not re-derivations).
- [ ] No `assert True` / tautologies.
- [ ] No over-mocking of stdlib where a real `tmp_path` file or fixture JSONL
      would do.
- [ ] No assertions on incidental whitespace/byte-exact formatting unrelated to
      the behavior under test.
- [ ] No bare `except:` / catch-and-ignore swallowing failures.
- [ ] No redundant private-helper tests that duplicate an existing end-to-end
      guarantee without adding a sharper one.
