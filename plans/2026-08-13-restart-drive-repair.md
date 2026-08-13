# Restart Drive Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a driven `restart` relaunch Claude Code with the real launch command, typed only once the terminal is actually accepting input again.

**Architecture:** Both observed defects have one root — nothing in the plugin ever identifies the `claude` process. `handoff_resume_command` assumes `$PPID` is it (it is the `sh -c` hook wrapper), and `_drive_shell_line` guesses at its shutdown with a fixed sleep. Task 1 adds a bounded parent-chain walk that finds the process by name; Task 2 replaces the sleep with a tmux-observable predicate on the pane's foreground command.

**Tech Stack:** bash 3.2-compatible shell (`scripts/_lib.sh`), Python 3 (`scripts/_watcher_lib.py`, `scripts/drive_when_idle.py`), bats-core for shell tests, pytest for Python tests, tmux for pane control.

**Spec:** none — this plan is its own spec. The defect evidence is in **Defects** below, captured from a live failure; Task 3 turns it into the repo's standing design record.

## Global Constraints

- Shell must run on **bash 3.2** (macOS): no `mapfile`, no associative arrays, no `${var,,}`.
- Every touched `.sh`/`.bats` file must pass `shellcheck -x`; a suppression carries its reason as a *second* comment.
- `/proc` is Linux-only. Every reader of it keeps its `ps` fallback, and the macOS gap already documented for embedded spaces stays a known gap — do not widen the claim.
- Tests never drive the user's tmux socket. The Python suites use `tests/conftest.py`'s `TmuxStub`; `tests/hook-test.bats` stubs `tmux` on `PATH` in `setup()`.
- `just precommit` is the gate. Run it before each commit, unprompted.
- A design change lands its `docs/changelog/` entry, its `docs/changelog.md` index line, and the `docs/design.md`/`CLAUDE.md` prose it invalidates **in the same pass** — that is Task 3, not an optional follow-up.
- No compat aliases. `HANDOFF_TEST_CMDLINE_PATH` is removed, not deprecated; every caller moves.

## Defects

Captured from a live restart in `~/c/handoff`. The shell received:

```
/bin/sh -c bash\ \$\{CLAUDE_PLUGIN_ROOT\}/scripts/stop-drive.sh --resume e8da0f4b-273f-4c46-831f-90c0dd42440f
bash: /scripts/stop-drive.sh: No such file or directory
```

**D1 — the wrong process's argv is replayed.** `scripts/_lib.sh:440` reads
`local pid="${1:-$PPID}"`. Claude Code runs the hook as `claude` →
`/bin/sh -c "bash …/stop-drive.sh"` → `bash stop-drive.sh`, so `$PPID` is the
`sh -c` wrapper. Its argv is the hook command line, and `--resume <sid>` got
appended to that. The unexpanded `${CLAUDE_PLUGIN_ROOT}` is a consequence, not
a separate bug: Claude Code puts that literal in the `sh -c` argv and lets `sh`
expand it from the environment, so the wrapper's `/proc/<pid>/cmdline` really
does contain it unexpanded. `printf %q` froze it, and a fresh login shell —
exporting no such variable — expanded it to empty.

Whether the `sh -c` wrapper survives at all is the shell's exec-optimisation
choice, so the distance from the hook script to `claude` is **not fixed** and a
"use the grandparent" rule would be as brittle as the current one.

**D2 — the relaunch line is typed into a terminal that is not listening.**
`_drive_shell_line` sleeps `HANDOFF_WATCHER_SHELL_SETTLE` (default 1.0s) after
`/exit` confirms, then types. Claude Code stops consuming input well before it
releases the terminal, and a keystroke sent in that window is dropped leaving
no trace — the observed symptom was the command text arriving but its Enter
never registering, needing a manual keypress. This is not a shell *startup*
race: the parent shell was running the whole time.

**Why the suite is green on D1.** All three `handoff_resume_command` tests set
`HANDOFF_TEST_CMDLINE_PATH`, which replaces the whole `/proc/$pid/cmdline`
expression. The seam substitutes for exactly the subexpression that is wrong,
so `${1:-$PPID}` has never been executed by a test. Replacing that seam with a
fake process *tree* is what makes D1 expressible, and is therefore part of
Task 1 rather than a cleanup.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scripts/_lib.sh` | Add `handoff_proc_root`, `handoff_proc_argv0`, `handoff_proc_ppid`, `handoff_claude_pid`; rewrite `handoff_resume_command` to walk | 1 |
| `tests/hook-test.bats` | Fake-proc-tree helper; port 3 tests to the new seam; add walk, fallback and cycle tests | 1 |
| `scripts/_watcher_lib.py` | Add `pane_foreground` and `wait_for_foreground_change` | 2 |
| `scripts/drive_when_idle.py` | Capture the baseline foreground in `main`; gate `_drive_shell_line` on the predicate | 2 |
| `tests/conftest.py` | Teach `TmuxStub` to answer `#{pane_current_command}` | 2 |
| `tests/test_watcher_lib.py` | Predicate tests | 2 |
| `tests/test_drive_when_idle.py` | Update shell-line tests; add the not-typed-while-claude-is-foreground gate | 2 |
| `docs/changelog/2026-08-13-restart-drive-repair.md`, `docs/changelog.md`, `docs/design.md`, `CLAUDE.md` | Design record | 3 |

`stop-drive.sh` is **not** modified: it already calls
`handoff_resume_command "" "$sid"`, and `""` still means "default to `$PPID`" —
what changes is that `$PPID` becomes the *start* of a walk rather than the
answer.

---

### Task 1: Resolve the Claude Code process by walking the parent chain

**Files:**
- Modify: `scripts/_lib.sh:439-460` (`handoff_resume_command`), adding four helpers above it
- Test: `tests/hook-test.bats:543-586` (the `_lib.sh: handoff_resume_command` block)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `handoff_proc_root()` → prints `${HANDOFF_TEST_PROC_ROOT:-/proc}`, one line.
  - `handoff_proc_argv0(pid)` → prints argv[0] of `pid`, or empty. rc 0.
  - `handoff_proc_ppid(pid)` → prints the parent pid of `pid`, or empty. rc 0.
  - `handoff_claude_pid(start_pid)` → prints the ancestor pid whose argv[0] basename is `claude`; rc 1 and no output when the bounded walk finds none.
  - `handoff_resume_command(start_pid, sid)` → unchanged signature and unchanged output contract; `start_pid` is now the **start of the walk**, defaulting to `$PPID`.
- Retires: `HANDOFF_TEST_CMDLINE_PATH`. Replaced by `HANDOFF_TEST_PROC_ROOT`, a directory holding `<pid>/cmdline` and `<pid>/status` per process.

- [ ] **Step 1: Write the failing tests**

In `tests/hook-test.bats`, replace the whole `--- _lib.sh: handoff_resume_command ---` block (lines 543-586) with the following. `resplit` is unchanged and stays.

```bash
# --- _lib.sh: handoff_resume_command ---

# Round-trip the output back through a shell to check the CONTRACT ("survives
# being retyped") rather than the exact quoting bash's %q happens to choose.
resplit() {
    bash -c 'eval "set -- $1"; printf "%s\n" "$@"' _ "$1"
}

# A fake process table: one directory per pid holding the two files the walk
# reads. /proc itself cannot be faked, and the pid SELECTION is the part that
# was wrong, so the seam has to be a tree — a single cmdline file substitutes
# for the very expression under test.
# $1=root $2=pid $3=ppid $4.. = argv
make_proc_entry() {
    local root="$1" pid="$2" ppid="$3"
    shift 3
    mkdir -p "$root/$pid"
    printf 'Name:\tx\nPPid:\t%s\n' "$ppid" > "$root/$pid/status"
    printf '%s\0' "$@" > "$root/$pid/cmdline"
}

# The tree a Stop hook actually runs in: claude spawns `/bin/sh -c "bash …"`,
# which spawns the hook script. $PPID stops at the wrapper.
make_restart_proc_tree() {
    local root="$1"
    make_proc_entry "$root" 100 50 claude --plugin-dir /foo
    make_proc_entry "$root" 101 100 /bin/sh -c 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/stop-drive.sh'
    make_proc_entry "$root" 102 101 bash /x/scripts/stop-drive.sh
}

@test "handoff_resume_command (walks past the sh -c hook wrapper to claude)" {
    root="$BATS_TEST_TMPDIR/proc"
    make_restart_proc_tree "$root"
    HANDOFF_TEST_PROC_ROOT="$root" run handoff_resume_command 102 "sess-99"
    [ "$status" -eq 0 ]
    got="$(resplit "$output")"
    [ "$got" = "claude
--plugin-dir
/foo
--resume
sess-99" ]
}

# A value containing a space (a --plugin-dir path, say) must survive as ONE
# argument once retyped, not split into two.
@test "handoff_resume_command (an argument containing a space survives whole)" {
    root="$BATS_TEST_TMPDIR/proc"
    make_proc_entry "$root" 110 50 claude --plugin-dir "/a path/with space"
    make_proc_entry "$root" 111 110 bash /x/scripts/stop-drive.sh
    HANDOFF_TEST_PROC_ROOT="$root" run handoff_resume_command 111 "sess-99"
    [ "$status" -eq 0 ]
    got="$(resplit "$output")"
    [ "$got" = "claude
--plugin-dir
/a path/with space
--resume
sess-99" ]
}

# No claude anywhere up the chain: the bare form still relaunches, losing only
# the flags. Strictly better than replaying somebody else's argv.
@test "handoff_resume_command (no claude ancestor: bare resume, still succeeds)" {
    root="$BATS_TEST_TMPDIR/proc"
    make_proc_entry "$root" 200 0 /sbin/init
    make_proc_entry "$root" 201 200 bash /x/scripts/stop-drive.sh
    HANDOFF_TEST_PROC_ROOT="$root" run handoff_resume_command 201 "sess-99"
    [ "$status" -eq 0 ]
    [ "$output" = "claude --resume sess-99" ]
}

@test "handoff_resume_command (no proc source readable at all: bare resume)" {
    HANDOFF_TEST_PROC_ROOT="$BATS_TEST_TMPDIR/nope" PATH="" \
        run handoff_resume_command 999 "sess-99"
    [ "$status" -eq 0 ]
    [ "$output" = "claude --resume sess-99" ]
}

# A pid whose parent is itself must end the walk, not spin forever.
@test "handoff_resume_command (a parent cycle terminates rather than hanging)" {
    root="$BATS_TEST_TMPDIR/proc"
    make_proc_entry "$root" 301 301 bash /x/loop
    HANDOFF_TEST_PROC_ROOT="$root" run handoff_resume_command 301 "sess-99"
    [ "$status" -eq 0 ]
    [ "$output" = "claude --resume sess-99" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/david/code/handoff && bats tests/hook-test.bats -f handoff_resume_command`

Expected: the walk test and the space test FAIL on the `[ "$got" = … ]`
assertion — a genuine assertion failure, not a missing function.
`handoff_resume_command` still exists and still returns 0, so the red is about
behaviour. With `HANDOFF_TEST_PROC_ROOT` unread by the old code, it reads the
real `/proc/102/cmdline` (absent) and falls through to `claude --resume
sess-99`, which is not the expected argv. The cycle test may pass before the
fix; that is expected — it guards the new loop, and is mutation-checked in
Step 5 rather than trusted here.

- [ ] **Step 3: Write the implementation**

In `scripts/_lib.sh`, insert these four helpers immediately **above**
`handoff_resume_command`, then replace that function's body. Definitions sit
after the entry point that reads them per the repo's ordering rule, so the
block goes directly above its one caller.

```bash
# The process table to read. Overridable so tests can build a fake tree: /proc
# cannot be faked, and the pid SELECTION below is what a single-file seam
# silently substituted for, which is how the wrong-pid defect stayed green.
handoff_proc_root() {
    printf '%s\n' "${HANDOFF_TEST_PROC_ROOT:-/proc}"
}

# argv[0] of $1, or empty. `read` reports EOF-without-delimiter as non-zero,
# which is the normal case for a single-field read, so its status is not
# evidence of failure here.
handoff_proc_argv0() {
    local src argv0=""
    src="$(handoff_proc_root)/$1/cmdline"
    if [[ -r "$src" ]]; then
        IFS= read -r -d '' argv0 < "$src" || true
        printf '%s\n' "$argv0"
        return 0
    fi
    ps -o command= -p "$1" 2>/dev/null | awk 'NR==1 {print $1}'
}

# The parent pid of $1, or empty. /proc/<pid>/status rather than …/stat: that
# file's second field is the executable name in parentheses and may itself
# contain spaces and parens, which is the classic way a field-index parse of
# it goes wrong.
handoff_proc_ppid() {
    local src
    src="$(handoff_proc_root)/$1/status"
    if [[ -r "$src" ]]; then
        awk '/^PPid:/ {print $2; exit}' "$src"
        return 0
    fi
    ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}

# The ancestor of $1 that is Claude Code itself, or rc 1 when the walk finds
# none. Claude Code runs a hook as `claude` -> `/bin/sh -c "bash …"` -> the
# script, so $PPID is the wrapper, whose argv is the hook command line and not
# a launch line anyone can replay. Whether that wrapper survives is the
# shell's exec-optimisation choice, so the depth is not fixed: walk it,
# bounded, and stop on a self-parent so a malformed table cannot spin.
handoff_claude_pid() {
    local pid="$1" depth=0 argv0 parent
    while [[ -n "$pid" && "$pid" != 0 ]] && (( depth < 10 )); do
        argv0="$(handoff_proc_argv0 "$pid")"
        if [[ "${argv0##*/}" == "claude" ]]; then
            printf '%s\n' "$pid"
            return 0
        fi
        parent="$(handoff_proc_ppid "$pid")"
        [[ "$parent" != "$pid" ]] || break
        pid="$parent"
        depth=$(( depth + 1 ))
    done
    return 1
}
```

Then replace `handoff_resume_command`'s body with:

```bash
handoff_resume_command() {
    local start="${1:-$PPID}" sid="$2" pid src
    pid="$(handoff_claude_pid "$start")" || pid=""
    local -a argv=()
    if [[ -n "$pid" ]]; then
        src="$(handoff_proc_root)/$pid/cmdline"
        if [[ -r "$src" ]]; then
            local part
            while IFS= read -r -d '' part; do argv+=("$part"); done < "$src"
        elif command -v ps >/dev/null 2>&1; then
            local line
            line="$(ps -o command= -p "$pid" 2>/dev/null || true)"
            if [[ -n "$line" ]]; then
                # shellcheck disable=SC2206  # accepted word-splitting, see above
                argv=($line)
            fi
        fi
    fi
    if (( ${#argv[@]} == 0 )); then
        printf 'claude --resume %s\n' "$sid"
        return 0
    fi
    printf '%q ' "${argv[@]}"
    printf -- '--resume %q\n' "$sid"
}
```

Update the comment block above `handoff_resume_command` (currently
`scripts/_lib.sh:423-426`) to say the argv is read from the ancestor the walk
identifies, not from `$PPID`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/david/code/handoff && bats tests/hook-test.bats -f handoff_resume_command`
Expected: 5 passing.

- [ ] **Step 5: Mutation-check the two load-bearing rows**

Neither row is trusted from a green run.

1. Delete the `[[ "$parent" != "$pid" ]] || break` line. Re-run: the cycle test
   must hang or fail. Restore it.
2. Change `handoff_claude_pid`'s call in `handoff_resume_command` back to using
   `$start` directly as the pid. Re-run: the walk test alone must go red, and
   the fallback tests must stay green. Restore.

Record both outcomes in the commit body. A row that stays green under its
mutation is not evidence and must be rebuilt before proceeding.

- [ ] **Step 6: Lint and gate**

Run: `cd /Users/david/code/handoff && shellcheck -x scripts/_lib.sh tests/hook-test.bats && just precommit`
Expected: shellcheck silent; `just precommit` green.

- [ ] **Step 7: Commit**

```bash
cd /Users/david/code/handoff
git add scripts/_lib.sh tests/hook-test.bats
git commit -m "fix: find the claude process instead of assuming \$PPID is it"
```

---

### Task 2: Type the relaunch only once the terminal is listening

**Files:**
- Modify: `scripts/_watcher_lib.py` (add two functions)
- Modify: `scripts/drive_when_idle.py:47-65` (`_drive_shell_line`) and `:163-174` (`main`)
- Modify: `tests/conftest.py:24-25` (the stub's `display-message` case) and `TmuxStub.__init__`
- Test: `tests/test_watcher_lib.py`, `tests/test_drive_when_idle.py:455-540`, `tests/test_tui_conformance.py` (the live premise check — the stub cannot verify what tmux really reports)

**Interfaces:**
- Consumes: nothing from Task 1 — the two tasks are independent and may land in either order.
- Produces:
  - `pane_foreground(pane: str) -> str` — tmux's `#{pane_current_command}` for the pane, stripped.
  - `wait_for_foreground_change(pane: str, baseline: str, timeout: float) -> bool` — True once the foreground command has read as something other than `baseline` twice consecutively; False on timeout.
  - `_drive_shell_line(pane: str, line: str, baseline: str, settle: float) -> None` — one added parameter, `baseline`, third positionally.
- Retires: nothing. `HANDOFF_WATCHER_SHELL_SETTLE` survives with a narrowed meaning — a bounded residual after the predicate, not the whole wait — and its default drops from 1.0 to 0.25.

- [ ] **Step 1: Teach the tmux stub to answer the foreground query**

The stub's `display-message` case currently `cat`s `cursor.txt` for every
query, so a second `display-message` caller would silently read the cursor. In
`tests/conftest.py`, replace that case in `_TMUX_STUB`:

```bash
  display-message)
    case "$*" in
      *pane_current_command*) cat "{stubdir}/foreground.txt" ;;
      *) cat "{stubdir}/cursor.txt" ;;
    esac ;;
```

and in `TmuxStub.__init__`, after the `self.cursor` block:

```python
        # The pane's foreground command. Defaults to the TUI, which is what it
        # reads as for every test that never exits it.
        self.foreground = stubdir / "foreground.txt"
        self.foreground.write_text("claude\n")
```

plus a setter beside `compose`:

```python
    def set_foreground(self, command: str) -> None:
        """Stage what tmux reports as the pane's foreground process."""
        self.foreground.write_text(f"{command}\n")
```

- [ ] **Step 2: Write the failing tests**

In `tests/test_watcher_lib.py`, add:

```python
def test_pane_foreground_reads_the_tmux_format(tmux_stub):
    tmux_stub.set_foreground("fish")
    env = {**os.environ, "PATH": tmux_stub.path_env()}
    out = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, %r); import _watcher_lib as w;"
         " print(w.pane_foreground('%%0'))" % str(SCRIPTS)],
        capture_output=True, text=True, env=env, check=True,
    )
    assert out.stdout.strip() == "fish"


def test_wait_for_foreground_change_times_out_while_claude_holds_the_pane(tmux_stub):
    tmux_stub.set_foreground("claude")
    env = {**os.environ, "PATH": tmux_stub.path_env()}
    out = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, %r); import _watcher_lib as w;"
         " print(w.wait_for_foreground_change('%%0', 'claude', 0.3))" % str(SCRIPTS)],
        capture_output=True, text=True, env=env, check=True,
    )
    assert out.stdout.strip() == "False"
```

Use whatever `SCRIPTS` path constant and subprocess idiom the file already
uses for the other primitives; match it rather than introducing a second
shape.

In `tests/test_drive_when_idle.py`, add the gate test beside the existing
shell-line tests:

```python
def test_shell_line_is_not_typed_while_claude_still_holds_the_pane(tmux_stub):
    """The relaunch must wait for Claude Code to release the terminal.

    Asserted on the DELAY between the /exit send and the relaunch send, not on
    suppression: wait_for_foreground_change gives up on timeout by design, so
    a pane that never changes is eventually typed into anyway. Only the gap
    proves the gate ran.
    """
    tmux_stub.set_foreground("claude")
    start = time.monotonic()
    run_walker(
        tmux_stub,
        "/exit",
        "claude --resume sess-42",
        env={
            "HANDOFF_WATCHER_EXIT_TIMEOUT": "0.5",
            "HANDOFF_WATCHER_SHELL_SETTLE": "0.01",
        },
    )
    elapsed = time.monotonic() - start
    assert "-l|claude --resume sess-42|" in tmux_stub.sent_text()
    assert elapsed >= 0.5
```

Use the file's own walker-invocation helper and env-passing idiom in place of
the `run_walker(...)` sketch above; the existing shell-line tests at
`tests/test_drive_when_idle.py:455-540` show the exact shape.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd /Users/david/code/handoff && pytest tests/test_watcher_lib.py tests/test_drive_when_idle.py -k "foreground or shell_line" -v`

Expected: the two `_watcher_lib` tests FAIL with `AttributeError: module
'_watcher_lib' has no attribute 'pane_foreground'`. That is a missing symbol,
not an assertion — so before moving on, add both functions as bodies that
`return ""` / `return True`, re-run, and confirm each test then fails on its
own **assertion**. That is the red this task is entitled to; a missing-module
failure proves only absence.

- [ ] **Step 4: Write the implementation**

In `scripts/_watcher_lib.py`, beside the other pane readers:

```python
def pane_foreground(pane: str) -> str:
    """The command tmux reports as the pane's foreground process."""
    result = subprocess.run(
        ["tmux", "display-message", "-p", "-t", pane, "#{pane_current_command}"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


def wait_for_foreground_change(pane: str, baseline: str, timeout: float) -> bool:
    """Wait until the pane's foreground command is no longer ``baseline``.

    Claude Code stops consuming input well before it releases the terminal,
    and a keystroke sent inside that window is dropped leaving no trace: the
    pane looks untouched and the line simply never appears. The foreground
    command reverting from Claude Code to the pane's own shell is the
    observable end of that window, which a fixed sleep can only guess at.

    Two consecutive readings, so a transient during teardown does not release
    the gate early. Returns False on timeout rather than raising — the walker
    owns failure for the whole sequence.
    """
    poll = _env_float("HANDOFF_WATCHER_FOREGROUND_POLL", 0.1)
    deadline = time.monotonic() + timeout
    seen = 0
    while time.monotonic() < deadline:
        if pane_foreground(pane) != baseline:
            seen += 1
            if seen >= 2:
                return True
        else:
            seen = 0
        time.sleep(poll)
    return False
```

In `scripts/drive_when_idle.py`, replace `_drive_shell_line` (lines 47-65):

```python
def _drive_shell_line(pane: str, line: str, baseline: str, settle: float) -> None:
    """Type one line into a bare shell prompt, following a confirmed /exit.

    _drive_line's checks assume the Claude Code TUI: composer_has_user_text
    and line_landed read the `❯` composer, is_unknown_command its "No commands
    match" text — none of which exists once the process has exited to a shell.
    So this line skips them and gates on the pane's foreground command
    instead: /exit confirming means SessionEnd fired, not that the terminal is
    accepting input again.

    The settle after the gate is a bounded residual, not the wait itself — the
    shell still redraws its prompt after it regains the foreground, and that
    part is not separately observable.
    """
    timeout = _env_float("HANDOFF_WATCHER_EXIT_TIMEOUT", 30.0)
    if not wait_for_foreground_change(pane, baseline, timeout):
        watcher_fail(
            f"`{line}` was never typed: the pane's foreground was still "
            f"`{baseline}` after {timeout}s, so Claude Code had not released "
            f"the terminal"
        )
    time.sleep(settle)
    _send_literal(pane, line)
    if not submit_consumed(pane):
        watcher_fail(
            f"`{line}` was typed and Entered, but no SessionStart(resume) followed"
        )
```

Add `wait_for_foreground_change` and `pane_foreground` to the import block at
`scripts/drive_when_idle.py:39`.

In `main` (lines 163-174):

```python
    verify_delay = _env_float("HANDOFF_WATCHER_VERIFY_DELAY", 0.5)
    shell_settle = _env_float("HANDOFF_WATCHER_SHELL_SETTLE", 0.25)
    # Sampled before any line is typed, while Claude Code is certainly still
    # the foreground process — after /exit there is nothing left to compare.
    baseline = pane_foreground(pane)

    for line in lines:
        if line.startswith("claude --resume "):
            _drive_shell_line(pane, line, baseline, shell_settle)
        else:
            _drive_line(pane, line, verify_delay)
    return 0
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd /Users/david/code/handoff && pytest tests/test_watcher_lib.py tests/test_drive_when_idle.py -v`
Expected: all pass, including the pre-existing shell-line tests. The one
asserting `elapsed >= 1` for the old default settle must be updated — its
premise (a 1.0s sleep) is gone. Rewrite it against the gate, not the sleep.

- [ ] **Step 6: Mutation-check the gate**

Delete the `if not wait_for_foreground_change(...)` block. Re-run: the delay
test from Step 2 alone must go red, and the other shell-line tests must stay
green. Restore, and record the outcome in the commit body.

- [ ] **Step 7: Check the premise against a live TUI**

The stub answers `#{pane_current_command}` with whatever the test staged, so
every test above passes on an *assumption*: that tmux reports `claude` while
the TUI runs and something else once it exits. If that is wrong — the format
reads `node`, or the pane's shell name throughout — the gate never opens and
every restart fails closed. The unit suite cannot catch it, because the stub
is the thing asserting the premise.

Run: `cd /Users/david/code/handoff && just tui-conformance`

Then, against the same live TUI it boots, record what the format actually
returns while Claude Code is in the foreground and after it exits:

```bash
tmux display-message -p -t "<the conformance pane>" '#{pane_current_command}'
```

If the two readings are equal, `wait_for_foreground_change` can never fire and
the design needs the `#{pane_pid}` alternative recorded in Task 3 instead —
stop and raise it rather than widening the timeout. If they differ, add the
observed pair to `tests/test_tui_conformance.py` so the premise is pinned by
the suite that runs against a real TUI, and note the tmux version it was
observed on: this is a format string's behaviour, not a documented contract.

- [ ] **Step 8: Gate**

Run: `cd /Users/david/code/handoff && just precommit`
Expected: green. `just tui-conformance` is deselected from it by design, so
Step 7 does not run here — that is why it is its own step.

- [ ] **Step 9: Commit**

```bash
cd /Users/david/code/handoff
git add scripts/_watcher_lib.py scripts/drive_when_idle.py tests/conftest.py \
        tests/test_watcher_lib.py tests/test_drive_when_idle.py
git commit -m "fix: wait for Claude Code to release the terminal before relaunching"
```

---

### Task 3: Record the design change

Its own task because the changelog entry describes **one** root cause behind
both fixes, so it cannot be written until both have landed. The repo's
convention makes the entry, its index line and the invalidated prose a single
pass, not a follow-up.

**Files:**
- Create: `docs/changelog/2026-08-13-restart-drive-repair.md`
- Modify: `docs/changelog.md` (one index line, newest first)
- Modify: `docs/design.md` — two mechanism paragraphs in `### Driving the TUI` (the argv source at 293-297, the settle at 370-371), one new subsection in `## Design decisions`, three in `## Rejected alternatives`
- Modify: `CLAUDE.md` (three stale descriptions, listed below)

**Interfaces:** consumes the behaviour of Tasks 1 and 2; produces no code.

- [ ] **Step 1: Write the changelog entry**

Create `docs/changelog/2026-08-13-restart-drive-repair.md`. It is a write-time
record and is never edited afterwards, so write what was believed today. It
must carry: the captured failing shell output from **Defects** above; the
`claude` → `sh -c` → script tree and why depth is not fixed; why the
single-file test seam kept D1 green; that D2 is Claude Code's shutdown window
rather than a shell startup race; and the rejected alternatives below.

Rejected alternatives to record:

- *Use the grandparent of the hook script.* Depth depends on whether the shell
  exec-optimises the `sh -c` wrapper away, so this is the same brittleness
  with a different constant.
- *Derive the claude pid from tmux's `#{pane_pid}`, walking up to the pane's
  own process and taking the child below it.* Exact, and independent of what
  the process is named — but `handoff_resume_command` is called before the
  tmux check in `stop-drive.sh`, so it must also work on the not-in-tmux paste
  path, where there is no pane. Kept as the fallback plan if the name-based
  walk proves fragile.
- *Lengthen `HANDOFF_WATCHER_SHELL_SETTLE`.* Tuning a constant against an
  unbounded shutdown; the failure mode returns under load and is silent.

- [ ] **Step 2: Add the index line**

At the top of the list in `docs/changelog.md`:

```markdown
- [2026-08-13 — Restart drive repair](changelog/2026-08-13-restart-drive-repair.md) — the relaunch replayed the hook wrapper's argv and typed into a terminal Claude Code had not released
```

- [ ] **Step 3: Rewrite the invalidated prose**

In `CLAUDE.md`, three statements are now false:

1. Under `scripts/_lib.sh`: "this reads them fresh from `/proc/<pid>/cmdline`" —
   must say the pid comes from a bounded parent-chain walk that identifies
   `claude` by argv[0] basename, with the bare `claude --resume <sid>` fallback
   when the walk finds none.
2. Under `scripts/_lib.sh`: "`HANDOFF_TEST_CMDLINE_PATH` substitutes a fixture
   file for the `/proc` path in tests" — the variable is gone. Name
   `HANDOFF_TEST_PROC_ROOT` and say it substitutes a fake process *tree*,
   because a single file substituted for the expression under test.
3. Under `scripts/drive_when_idle.py`: "A fixed `HANDOFF_WATCHER_SHELL_SETTLE`
   stands in" — replace with the foreground-change gate, and state the settle's
   narrowed role as a bounded residual.

- [ ] **Step 4: Rewrite `docs/design.md`**

The design doc is present-tense standing truth. Mechanism descriptions get
**updated**; rationale paragraphs are preserved. No dated entry goes here —
dated rationale lives in `docs/changelog/`. Four edits, in the doc's own
style: bolded lead-in prose subsections, each closing with a bracketed
changelog link. Never a table.

**4a. `### Driving the TUI`, the argv paragraph (lines 293-297).** After the
existing sentence ending "since that is the one place with access to that
argv.", the mechanism is now:

> Finding that process is a bounded walk up the parent chain, matching
> argv[0]'s basename against `claude`. The hook runs as `claude` →
> `/bin/sh -c "bash …"` → the script, and whether that wrapper survives is
> the shell's exec-optimisation choice, so its distance from the hook is not
> fixed. A walk that finds nothing falls back to a bare
> `claude --resume <sid>`, relaunching without the flags rather than
> replaying an argv that is not a launch line.

**4b. `### Driving the TUI`, the settle sentence (lines 370-371).** Replace
"A fixed settle (`HANDOFF_WATCHER_SHELL_SETTLE`) stands in for the composer
checks on that one line." with:

> What stands in is the pane's own foreground command. Claude Code stops
> consuming input well before it releases the terminal, and a keystroke sent
> inside that window is dropped leaving no trace, so the line waits until
> `#{pane_current_command}` reads as something other than the baseline
> sampled before the sequence began. `HANDOFF_WATCHER_SHELL_SETTLE` survives
> that gate as a bounded residual: the shell still redraws its prompt once it
> has the foreground back, and that part is not separately observable.

**4c. Append to `## Design decisions`:**

> **The `claude` process is found, never assumed.** Both halves of a driven
> restart need it — the argv to replay, and the moment it has let go of the
> terminal. `$PPID` inside a hook is the `/bin/sh -c` wrapper Claude Code
> spawns, whose argv is the hook command line, so replaying it relaunched the
> hook with `--resume` appended and carried an unexpanded
> `${CLAUDE_PLUGIN_ROOT}` that a fresh login shell resolved to nothing. One
> bounded parent-chain walk answers both questions.
> [Restart drive repair](changelog/2026-08-13-restart-drive-repair.md)

**4d. Append to `## Rejected alternatives`** — three subsections, each
closing with the same link:

> **Taking the hook script's grandparent as `claude`** — the `/bin/sh -c`
> wrapper survives or is exec-optimised away at the shell's discretion, so a
> fixed depth is the same brittleness under a different constant.
>
> **Deriving the pid from tmux's `#{pane_pid}`** — exact, and indifferent to
> what the process is named, but `handoff_resume_command` runs before the
> tmux check in `stop-drive.sh` and must also serve the not-in-tmux paste
> path, where there is no pane to ask.
>
> **Lengthening `HANDOFF_WATCHER_SHELL_SETTLE`** — tuning a constant against
> an unbounded shutdown. The failure returns under load, and it is silent:
> the pane looks untouched.

Check the surrounding sections for any other mechanism paragraph the two
fixes falsify. A stale architecture description outlives its decision
otherwise — the known failure mode is a decision being superseded while four
mechanism descriptions elsewhere still narrate the old one.

- [ ] **Step 5: Gate and commit**

```bash
cd /Users/david/code/handoff
just precommit
git add docs/changelog/2026-08-13-restart-drive-repair.md docs/changelog.md \
        docs/design.md CLAUDE.md
git commit -m "docs: record the restart drive repair"
```

---

## Self-Review

**Coverage.** D1 → Task 1. D2 → Task 2. The green-suite explanation → Task 1
Step 1's seam replacement. Design record → Task 3. No defect is unassigned.

**Type consistency.** `handoff_resume_command`'s signature is unchanged, so
`stop-drive.sh:68` needs no edit — verified against the call
`handoff_resume_command "" "$sid"`, where `""` still selects the `$PPID`
default. `_drive_shell_line` gains one positional parameter and has exactly
one caller, updated in the same step. `HANDOFF_TEST_PROC_ROOT` replaces
`HANDOFF_TEST_CMDLINE_PATH` at all four of its uses (three tests plus the
`_lib.sh` reader).

**Known soft spots**, flagged rather than hidden:

- The walk identifies Claude Code by argv[0] basename `claude`. A launch as
  `node …/cli.js` matches nothing and takes the bare-resume fallback, losing
  flags. Acceptable — it is strictly better than today, and the tmux
  `#{pane_pid}` alternative is recorded in Task 3 for when it is not.
- Two test bodies in Task 2 Step 2 are sketched against helpers whose exact
  names live in the existing files; each step says to match the file's own
  idiom rather than introduce a second shape. An executor must read the
  neighbouring tests before writing them.
- `pane_foreground` adds a `tmux display-message` call to the walker's poll
  loop. It runs only on the restart path, after `/exit`, so it costs nothing
  on the compact and clear transitions.
