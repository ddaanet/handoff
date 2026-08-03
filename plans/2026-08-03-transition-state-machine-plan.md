# One transition, one file, explicit state — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `.claude/autodrive` and `.claude/autodrive.pending` into one
file whose first line names its state, so every gate reads a field instead of
choosing a filename.

**Architecture:** `handoff_drive_read` gains `DRIVE_STATE` from line 1; the kind
moves to line 2 and every slot below it shifts by one. `stop-drive.sh` rewrites
line 1 in place (`handoff_drive_arm`) where it used to `mv`, both loaders gate
on `pending` alongside their kind, and the `UserPromptSubmit` sweep gates on
`armed`. No behaviour changes.

**Tech Stack:** bash 3.2-compatible shell, `jq`, bats.

**Spec:** [`2026-08-03-transition-state-machine-design.md`](2026-08-03-transition-state-machine-design.md).
Read it before Task 1; every decision below is justified there.

**Execution.** Task 1 is one commit and cannot be split. The file format changes,
so the parser and all six writers/readers move together — any intermediate state
leaves the suite red and the plugin broken, and this repo does not build
migration paths for a user base of one. It is large but mechanical: the shape is
fixed, and the rows are given in full. Task 2 is separable and is the one place
this plan goes beyond the spec — a reviewer can reject it without touching Task
1. **Task 3 is not delegated.** The changelog entry is a write-time record of
reasoning that lives in the spec and the session that produced it, and
`docs/design.md`, `README.md` and `CLAUDE.md` are written in a voice a
context-free agent does not have.

## Global Constraints

- **No migration and no back-compat branch.** A session mid-transition across
  the upgrade sees a file it cannot parse and reports it malformed. That is the
  correct outcome.
- **One file, `.claude/autodrive`, in every state.** `HANDOFF_REL_DRIVE_PENDING`
  and the string `autodrive.pending` are gone from the repo when Task 1 lands —
  including from comments.
- **One fact per line**, the file's existing idiom: line 1 state, line 2 kind,
  commands and prose below. Every command literal stays pinned to its slot.
- Line counts in `_handoff_drive_expect` and the slot numbers in
  `_handoff_drive_command` / `_handoff_drive_prose` count the **whole file**,
  state line included. `rename` 3, `compact` 2 or 4, `clear` 5.
- bash 3.2 (macOS system bash): no `mapfile`, and arrays expand as
  `${DRIVE_BEFORE[@]+"${DRIVE_BEFORE[@]}"}`.
- `set -euo pipefail` and `# shellcheck source-path=SCRIPTDIR source=_lib.sh`
  above the `source` line, as in every sibling script.
- No `2>/dev/null` blanket suppression (house rule); guard instead.
- Every step's tests are `bats tests/hook-test.bats` (plus
  `tests/checkpoint.bats` where named); the full gate before any commit is
  `just precommit`.

## File Structure

| file | change | responsibility |
|---|---|---|
| `scripts/_lib.sh` | modify | `DRIVE_STATE`, the state line, `handoff_drive_arm`; delete `HANDOFF_REL_DRIVE_PENDING` |
| `scripts/stop-drive.sh` | modify | gate on `armed`; arm-or-delete in place |
| `scripts/load-handoff.sh` | modify | gate on `pending` + kind `clear` |
| `scripts/load-compact.sh` | modify | gate on `pending` + kind `compact` |
| `scripts/report-watcher-failure.sh` | modify | sweep on `armed`; the failure branch clears a `pending` |
| `scripts/checkpoint.sh` | modify | write the state line |
| `scripts/write-drive.sh` | modify (Task 2) | the agent's channel writes `armed` only |
| `skills/autoname/SKILL.md` | modify | the sentinel it writes gains its state line |
| `skills/handoff-continue/SKILL.md` | modify | four lines become five |
| `skills/compact-continue/SKILL.md` | modify | three lines become four |
| `skills/precompact/SKILL.md` | modify | one line becomes two |
| `tests/hook-test.bats` | modify | every seeded sentinel, plus the state-gate rows |
| `tests/checkpoint.bats` | modify | the rename sentinel's asserted content |
| `.gitignore` | modify | the comment naming `.pending` |
| `docs/changelog/2026-08-03-one-transition-one-file.md` | create | write-time record |
| `docs/changelog.md`, `docs/design.md`, `README.md`, `CLAUDE.md` | modify | prose the change invalidates |

---

### Task 1: The state field

**Files:**
- Modify: `scripts/_lib.sh:22-32` (constants), `:148-194` (`handoff_drive_read`),
  and a new `handoff_drive_arm` after `handoff_drive_has_source`
- Modify: `scripts/stop-drive.sh:27-86`
- Modify: `scripts/load-handoff.sh:35-44`
- Modify: `scripts/load-compact.sh:29-45`
- Modify: `scripts/report-watcher-failure.sh:80-101`
- Modify: `scripts/checkpoint.sh:254`
- Modify: `skills/autoname/SKILL.md:20-26`, `skills/handoff-continue/SKILL.md`
  (the "Exactly four lines" block), `skills/compact-continue/SKILL.md` (the
  "Exactly three lines" block), `skills/precompact/SKILL.md:67-71`
- Test: `tests/hook-test.bats` (shape matrix ~236-365; `seed_pending` ~627;
  `seed_drive` ~710; the `stop-drive`, `load-compact`, `load-handoff` and
  `report-watcher-failure` blocks), `tests/checkpoint.bats:442-458`

**Interfaces:**
- Produces: `DRIVE_STATE` — set by `handoff_drive_read` in the caller's scope,
  alongside `DRIVE_KIND`, `DRIVE_BEFORE`, `DRIVE_AFTER`, `DRIVE_ERR`. One of
  `armed` or `pending`.
- Produces: `handoff_drive_arm <file> <state>` → rewrites line 1 of `<file>` to
  `<state>`, preserving every line below it, replacing the file atomically.
  Returns 0 on success. Task 2 does not call it; the next pass's
  `handoff-approved` does.
- Consumes: nothing new.

- [ ] **Step 1: Restate every seeded sentinel in the tests**

This is the mechanical half and it comes first, so the rows are red for the
right reason. Three helpers and their callers.

In `tests/hook-test.bats`, `read_drive` (~line 248) keeps its body — it writes
its arguments verbatim, and every caller must now pass the state line, because
the error messages count the whole file. Update each row in the shape matrix:

```bash
@test "handoff_drive_read (rename): one before-line, no after-line" {
    read_drive "armed" "rename" "/rename Driven Transitions"
    [ "$DRIVE_STATE" = armed ]
    [ "$DRIVE_KIND" = rename ]
    [ "${#DRIVE_BEFORE[@]}" -eq 1 ]
    [ "${DRIVE_BEFORE[0]}" = "/rename Driven Transitions" ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (compact): command before, prose after" {
    read_drive "armed" "compact" "/compact focus on the parser" "continue with task 3"
    [ "$DRIVE_KIND" = compact ]
    [ "${DRIVE_BEFORE[0]}" = "/compact focus on the parser" ]
    [ "${DRIVE_AFTER[0]}" = "continue with task 3" ]
}

@test "handoff_drive_read (compact, bare command): accepted, /compact takes no argument" {
    read_drive "armed" "compact" "/compact" "continue with task 3"
    [ "${DRIVE_BEFORE[0]}" = "/compact" ]
}

# FR-G: the kind line alone. Nothing is typed, but the transition is expected,
# and that expectation is what the frame's re-injection is gated on.
@test "handoff_drive_read (compact, kind line alone): legal, both sequences empty" {
    read_drive "armed" "compact"
    [ "$DRIVE_KIND" = compact ]
    [ "${#DRIVE_BEFORE[@]}" -eq 0 ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (clear): two before-lines in order, prose after" {
    read_drive "armed" "clear" "/rename A Title" "/clear" "pick up per the task file"
    [ "$DRIVE_KIND" = clear ]
    [ "${#DRIVE_BEFORE[@]}" -eq 2 ]
    [ "${DRIVE_BEFORE[0]}" = "/rename A Title" ]
    [ "${DRIVE_BEFORE[1]}" = "/clear" ]
    [ "${DRIVE_AFTER[0]}" = "pick up per the task file" ]
}

# The state a Stop has already consumed. The parser does not know which caller
# wants which state — it reports the value and the gates decide.
@test "handoff_drive_read (pending): parsed like any other state" {
    read_drive "pending" "clear" "/rename A Title" "/clear" "pick up per the task file"
    [ "$DRIVE_STATE" = pending ]
    [ "$DRIVE_KIND" = clear ]
    [ "${DRIVE_AFTER[0]}" = "pick up per the task file" ]
}

@test "handoff_drive_read (unknown kind): rejected, naming the kinds" {
    run read_drive "armed" "reboot" "/reboot"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition kind"* ]]
}

@test "handoff_drive_read (unknown state): rejected, naming the states" {
    run read_drive "held" "clear" "/rename A Title" "/clear" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition state"* ]]
    [[ "$output" == *"held"* ]]
}

# The state line alone. It says which state, but there is no transition for it
# to be the state of.
@test "handoff_drive_read (state line alone): rejected, naming the missing kind" {
    run read_drive "armed"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition kind"* ]]
}

# The old autorename shape, and the shape this pass replaces. Neither has a
# state line, so both fail on line 1 rather than on anything below it.
@test "handoff_drive_read (bare title, the old autorename shape): rejected" {
    run read_drive "Some Session Title"
    [ "$status" -ne 0 ]
}

@test "handoff_drive_read (a pre-state-line sentinel): rejected on line 1" {
    run read_drive "clear" "/rename A Title" "/clear" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition state"* ]]
}

@test "handoff_drive_read (empty file): rejected" {
    run read_drive ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition state"* ]]
}

@test "handoff_drive_read (wrong line count for the kind): rejected, naming the count" {
    run read_drive "armed" "rename" "/rename A Title" "extra line"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly 3 lines"* ]]

    run read_drive "armed" "clear" "/rename A Title" "/clear"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly 5 lines"* ]]

    run read_drive "armed" "compact" "/compact" "continue" "extra"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly 4 lines"* ]]
}

@test "handoff_drive_read (command literal not in the kind's slot): rejected" {
    run read_drive "armed" "clear" "/clear" "/rename A Title" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"line 3"* ]]

    run read_drive "armed" "compact" "compact now" "continue"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/compact"* ]]
}

@test "handoff_drive_read (/rename with no argument): rejected" {
    run read_drive "armed" "rename" "/rename"
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-empty argument"* ]]

    run read_drive "armed" "rename" "/rename    "
    [ "$status" -ne 0 ]
}

@test "handoff_drive_read (/clear with an argument): rejected" {
    run read_drive "armed" "clear" "/rename A Title" "/clear now" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly"* ]]
}

@test "handoff_drive_read (empty continuation prompt): rejected" {
    run read_drive "armed" "compact" "/compact" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not be empty"* ]]
}

@test "handoff_drive_read (continuation prompt beginning with /): rejected" {
    run read_drive "armed" "clear" "/rename A Title" "/clear" "/resume the work"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not begin"* ]]
}
```

Then the two seed helpers. `seed_pending` and `seed_drive` write the same path
now and differ only in the state they stamp — which is the whole point of the
change, and keeping both names keeps every call site reading as it did:

```bash
# Seed .claude/autodrive under $1 in state `armed` — what an agent or the
# checkpoint writes — with the remaining args as the lines below it.
seed_drive() {
    local dir="$1"; shift
    printf '%s\n' "armed" "$@" > "$dir/.claude/autodrive"
}

# The same file in state `pending`: a transition Stop has already armed, waiting
# on the SessionStart that confirms it.
seed_pending() {
    local dir="$1"; shift
    printf '%s\n' "pending" "$@" > "$dir/.claude/autodrive"
}
```

`seed_drive` lives at ~line 711 and `seed_pending` at ~line 628, each above the
block that first uses it. Leave them where they are; `bats` sources the whole
file before running.

Now replace every `.claude/autodrive.pending` path in an assertion with
`.claude/autodrive`, and give the two "left for the other loader" rows a state
assertion so they cannot pass on a file that was consumed and rewritten:

```bash
# load-handoff block
@test "load-handoff (clear, pending of kind compact: left for SessionStart(compact))" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    [ "$(sed -n 2p "$tmp/.claude/autodrive")" = "compact" ]
}

# load-compact block
@test "load-compact (pending of kind clear: left for SessionStart(clear))" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    [ "$(sed -n 2p "$tmp/.claude/autodrive")" = "clear" ]
}
```

In `stop-drive`, the three rows that asserted a `.pending` file appeared now
assert the state was rewritten in place. Retitle them — "renames to .pending"
describes a mechanism that no longer exists:

```bash
@test "stop-drive (kind with a confirming source: rewrites to pending, reports armed)" {
    seed_drive "$tmp" "compact" "/compact keep the parser work" "continue with task 3"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    echo "$output" | jq -e '.systemMessage | test("/compact keep the parser work")' >/dev/null
}

# `rename` has no loader, so nothing would ever clear a pending armed for it.
@test "stop-drive (kind rename: deletes the sentinel outright)" {
    seed_drive "$tmp" "rename" "/rename Driven Transitions"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("/rename Driven Transitions")' >/dev/null
}

# FR-G: the prepare-only marker. Nothing is typed and nothing is spawned; the
# pending file alone is the whole effect, and it is what SessionStart(compact)
# gates the frame re-injection on.
@test "stop-drive (empty before-sequence: leaves it pending, spawns nothing)" {
    seed_drive "$tmp" "compact"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    echo "$output" | jq -e '.systemMessage | test("nothing to type")' >/dev/null
}

@test "stop-drive (worktree cwd: arms the worktree file)" {
    wt="$(make_worktree wtS)"
    seed_drive "$wt" "compact" "/compact" "continue with task 3"
    run_stop_drive "$wt" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$wt/.claude/autodrive")" = "pending" ]
}
```

The remaining `[ ! -e "$tmp/.claude/autodrive.pending" ]` assertions — in
*"stop-drive (not in tmux…)"*, *"stop-drive (malformed file…)"*,
*"load-compact (pending present…)"*, *"load-compact (not in tmux…)"*,
*"load-compact (empty after-sequence…)"*, *"load-compact (worktree cwd…)"*,
*"load-handoff (clear, pending present…)"*, *"load-handoff (clear, pending
present but NO frame…)"*, *"load-handoff (clear, not in tmux…)"*,
*"load-handoff (clear, malformed pending…)"* and *"report-watcher-failure
(clears a stranded pending file)"* — become
`[ ! -e "$tmp/.claude/autodrive" ]` (or `"$wt/…"`). Where a row asserted both
paths were gone, one assertion is now enough; delete the duplicate rather than
leaving two identical lines.

**Delete** *"report-watcher-failure (stale autodrive leaves .pending alone)"*
(~line 1318). It seeds both files at once, which is exactly the state this
change makes unrepresentable. Its intent — a file in flight is not swept —
becomes a state row in Step 2, over the one file.

Finally, in `tests/checkpoint.bats`, the rename sentinel gains its line
(~442-458):

```bash
    [ "$(cat "$repo/.claude/autodrive")" = "armed
rename
/rename Some Title" ]
```

and the `wc -l` assertion in the whitespace-flattening row becomes `-eq 3`.
Read the surrounding rows before editing: the exact title strings differ
between them.

- [ ] **Step 2: Write the state-gate rows**

These are the rows the change exists for. Each is paired with a positive that
already exists, over the same fixture, so a mutation has somewhere to show.

Append to the `stop-drive` block:

```bash
# The consume-before-spawn guarantee, stated directly. A pending file is a
# transition already in flight — its confirming SessionStart has not fired yet —
# and a Stop in the window between the two must not retype the sequence. That
# window is real: the walker submits its lines as ordinary prompts, and each one
# ends a turn.
@test "stop-drive (pending file: ignored, left untouched)" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
}
```

Append to the `load-handoff` block:

```bash
# Each loader consumes only a transition in flight. An armed file belongs to a
# Stop that has not fired — the agent wrote it and the turn ended on an Esc, so
# the sweep is what deals with it, not this.
@test "load-handoff (clear, armed file: not consumed, left for the sweep)" {
    seed_drive "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "armed" ]
    echo "$output" | jq -e '.systemMessage | test("pick up") | not' >/dev/null
}
```

Append to the `load-compact` block:

```bash
@test "load-compact (armed file: not consumed, no frame)" {
    seed_drive "$tmp" "compact" "/compact" "continue with task 3"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "armed" ]
}
```

Append to the `report-watcher-failure` block, in place of the deleted row:

```bash
# A pending file is legitimate for the whole Stop -> transition window, and that
# window contains the walker's own submits — each of which is a
# UserPromptSubmit. Sweeping one here would race SessionStart(compact|clear) and
# kill a live continuation. Only the failure branch above, which acts on
# something the walker observed itself, may clear one.
@test "report-watcher-failure (pending file: left alone, no report)" {
    seed_pending "$tmp" "compact" "/compact" "continue"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
}
```

And the arm helper's own rows, at the end of the shape-matrix block:

```bash
# --- _lib.sh: handoff_drive_arm ---

# Everything below line 1 is copied through untouched: the arm never has to know
# the kind's shape, which is what lets one helper serve Stop and, in the next
# pass, handoff-approved.
@test "handoff_drive_arm (rewrites line 1, preserves every line below)" {
    printf '%s\n' "armed" "clear" "/rename A Title" "/clear" "pick up per the task file" \
        > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_arm "$BATS_TEST_TMPDIR/sentinel" pending
    [ "$(cat "$BATS_TEST_TMPDIR/sentinel")" = "pending
clear
/rename A Title
/clear
pick up per the task file" ]
}

# The FR-G marker is two lines, so the tail below line 1 is a single line.
@test "handoff_drive_arm (two-line file: still just the state line)" {
    printf '%s\n' "armed" "compact" > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_arm "$BATS_TEST_TMPDIR/sentinel" pending
    [ "$(cat "$BATS_TEST_TMPDIR/sentinel")" = "pending
compact" ]
}

# Readers exist concurrently — both loaders and Stop parse this file, and the
# walker stats it — so a half-written file must never be observable under the
# real name. The temp lands beside it and is renamed over it.
@test "handoff_drive_arm (leaves no temp file behind)" {
    printf '%s\n' "armed" "compact" "/compact" "continue" > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_arm "$BATS_TEST_TMPDIR/sentinel" pending
    [ "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'sentinel*' | wc -l)" -eq 1 ]
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bats tests/hook-test.bats`
Expected: the shape-matrix rows fail on the state line being read as the kind
(`transition kind — rename, compact or clear — not \`armed\``); the
`handoff_drive_arm` rows fail with `command not found`; every gate row fails
because the scripts still address `.pending`. Run
`bats tests/checkpoint.bats -f rename` too — the sentinel rows fail on the
missing `armed` line.

Confirm the failures are assertion failures, not `bats` errors, for every row
whose assertion is a *negative* (`[ "$output" = "" ]`, `[ ! -e … ]`). A row that
dies before reaching its assertion proves nothing.

- [ ] **Step 4: Teach the parser the state line**

In `scripts/_lib.sh`, delete `HANDOFF_REL_DRIVE_PENDING` and its comment
(lines 23-27), and rewrite `HANDOFF_REL_DRIVE`'s comment:

```bash
# The transition. One composer, one session, at most one transition in flight —
# so one file, whose *body* names both the transition and where it has got to.
# Line 1 is the state (armed -> pending -> gone), line 2 the kind. See
# docs/design.md, "The armed transition is a singleton".
# shellcheck disable=SC2034
HANDOFF_REL_DRIVE=".claude/autodrive"
```

Rewrite `handoff_drive_read`'s doc comment and body. The doc block's shape list
gains the state line:

```bash
# Parse and validate the sentinel ($1) into the caller's DRIVE_STATE, DRIVE_KIND,
# DRIVE_BEFORE (lines typed before the transition) and DRIVE_AFTER (lines typed
# into the session the transition opens). Returns 0 when well-formed; otherwise
# returns 1 with DRIVE_ERR set to a one-phrase reason naming the constraint that
# failed.
#
# Line 1 is the state and line 2 is the kind, and the kind fixes the shape — so
# the remaining lines need no separator, and each kind keeps its own rules:
#
#   armed    the transition this turn's Stop will arm
#   pending  armed, in flight, waiting on its confirming SessionStart
#
#   rename   /rename <title>
#   compact  /compact [directive]         + continuation prose
#   compact  (kind line alone: a transition is expected, nothing is typed)
#   clear    /rename <title>, /clear      + continuation prose
#
# The state is reported, never interpreted: which state a caller wants is the
# caller's business, and the parser serves the Stop gate, both loaders and the
# UserPromptSubmit sweep with one answer.
#
# The lines are literal keystrokes: the walker must not know which command any
# kind uses. Every prose line is a single line because in the TUI one Enter is
# one submit — an embedded newline would submit it early. Read with a `read` loop
# rather than mapfile: bash 3.2 (macOS system bash) has no mapfile, and for the
# same reason callers must expand the arrays as
# `${DRIVE_BEFORE[@]+"${DRIVE_BEFORE[@]}"}` — an empty array is an unbound
# variable under `set -u` before bash 4.4.
# shellcheck disable=SC2034  # assigned for the caller's scope
handoff_drive_read() {
    local file="$1" line n
    local -a lines=()
    DRIVE_STATE=""; DRIVE_KIND=""; DRIVE_BEFORE=(); DRIVE_AFTER=(); DRIVE_ERR=""

    while IFS= read -r line || [ -n "$line" ]; do
        lines+=("$line")
    done < "$file"

    n=${#lines[@]}
    if [ "$n" -eq 0 ]; then
        DRIVE_ERR="the file is empty; line 1 must be the transition state"
        return 1
    fi
    DRIVE_STATE="${lines[0]}"
    case "$DRIVE_STATE" in
        armed | pending) ;;
        *)
            DRIVE_ERR="line 1 must be the transition state — armed or pending — not \`$DRIVE_STATE\`"
            return 1 ;;
    esac

    if [ "$n" -eq 1 ]; then
        DRIVE_ERR="line 2 must be the transition kind — rename, compact or clear"
        return 1
    fi
    DRIVE_KIND="${lines[1]}"

    case "$DRIVE_KIND" in
        rename)
            _handoff_drive_expect "$n" 3 || return 1
            _handoff_drive_command "${lines[2]}" 3 "/rename" arg || return 1
            DRIVE_BEFORE=("${lines[2]}")
            ;;
        compact)
            # The kind line alone is the prepare-only marker: nothing is typed,
            # but the transition is expected, so the loader still injects.
            [ "$n" -eq 2 ] && return 0
            _handoff_drive_expect "$n" 4 || return 1
            _handoff_drive_command "${lines[2]}" 3 "/compact" optional || return 1
            _handoff_drive_prose "${lines[3]}" 4 || return 1
            DRIVE_BEFORE=("${lines[2]}")
            DRIVE_AFTER=("${lines[3]}")
            ;;
        clear)
            _handoff_drive_expect "$n" 5 || return 1
            _handoff_drive_command "${lines[2]}" 3 "/rename" arg || return 1
            _handoff_drive_command "${lines[3]}" 4 "/clear" none || return 1
            _handoff_drive_prose "${lines[4]}" 5 || return 1
            DRIVE_BEFORE=("${lines[2]}" "${lines[3]}")
            DRIVE_AFTER=("${lines[4]}")
            ;;
        *)
            DRIVE_ERR="line 2 must be the transition kind — rename, compact or clear — not \`$DRIVE_KIND\`"
            return 1
            ;;
    esac
    return 0
}
```

- [ ] **Step 5: Add the arm helper**

In `scripts/_lib.sh`, immediately after `handoff_drive_has_source`:

```bash
# Rewrite the sentinel ($1) into state $2, preserving every line below the
# first. The state is the only field any transition changes, so one helper
# serves them all and none of them has to know the kind's shape.
#
# Atomic: a sibling temp file renamed over the original. Concurrent readers
# exist — both loaders and Stop parse this file, and the walker stats it — so a
# partially written file must never be observable under the real name. The temp
# lands in the same directory because rename(2) is only atomic within one
# filesystem, and .claude/autodrive* is gitignored, so a temp orphaned by a kill
# is never committed.
handoff_drive_arm() {
    local file="$1" state="$2" tmp="$1.arming.$$"
    if ! { printf '%s\n' "$state"; tail -n +2 "$file"; } > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$file"
}
```

- [ ] **Step 6: Gate `stop-drive.sh` on `armed`**

Replace lines 27-48. The `armed`/`pending` variable pair becomes one `drive`:

```bash
drive="$cwd/$HANDOFF_REL_DRIVE"

[[ -f "$drive" ]] || exit 0

if ! handoff_drive_read "$drive"; then
    # write-drive.sh already told the agent in-turn; consuming the file here
    # stops the same complaint from repeating at every subsequent Stop.
    rm -f "$drive"
    jq -nc --arg e "$DRIVE_ERR" \
        '{systemMessage: ("handoff: autodrive malformed — " + $e + "; discarded, transition not armed.")}'
    exit 0
fi

# Only an armed transition is this turn's to arm. A pending one is already in
# flight, waiting on its confirming SessionStart, and the window between the two
# contains ordinary turns — the walker submits each of its lines as a prompt.
# Re-arming from that state would retype the whole sequence.
[[ "$DRIVE_STATE" == "armed" ]] || exit 0

# Leave `armed` BEFORE spawning: a later Stop in this session must not re-arm. A
# kind with a confirming SessionStart goes to `pending` for that loader to
# consume; `rename` has no loader, so nothing would ever clear a pending for it.
if handoff_drive_has_source "$DRIVE_KIND"; then
    handoff_drive_arm "$drive" pending
else
    rm -f "$drive"
fi
```

Then, further down: the non-tmux branch's `rm -f "$pending"` becomes
`rm -f "$drive"`, and the export becomes `export HANDOFF_PENDING_FILE="$drive"`
— the walker's `submit_consumed` waits for that path to disappear, and
`pending → gone` is still a deletion. Rewrite the comment above the export
accordingly ("the .pending file disappearing" → "this file disappearing").

- [ ] **Step 7: Gate both loaders on `pending`**

`scripts/load-compact.sh`, lines 29-45:

```bash
drive="$cwd/$HANDOFF_REL_DRIVE"
[[ -f "$drive" ]] || exit 0

if ! handoff_drive_read "$drive"; then
    rm -f "$drive"
    jq -nc --arg e "$DRIVE_ERR" \
        '{systemMessage: ("handoff: autodrive malformed — " + $e + "; not resuming.")}'
    exit 0
fi

# Only a transition in flight is ours to complete, and only our own kind. An
# armed file belongs to a Stop that has not fired; a pending `clear` armed in
# this session and overtaken by a threshold auto-compaction would otherwise fire
# its continuation into the session the clear was meant to replace.
[[ "$DRIVE_STATE" == "pending" && "$DRIVE_KIND" == "compact" ]] || exit 0

# Consume unconditionally: the continuation fires at most once per compaction.
rm -f "$drive"
```

Rewrite the header comment's second paragraph, which names the file:
"Consuming `.claude/autodrive` is itself the confirmation the walker was waiting
on for the `/compact` line it typed: the file disappearing is what tells that
watcher the compaction happened." Rewrite the third paragraph's "no-pending
path" as "no-transition path".

`scripts/load-handoff.sh`, lines 35-44:

```bash
drive="$cwd/$HANDOFF_REL_DRIVE"
if [[ "$hook_source" == "clear" && -f "$drive" ]]; then
    if ! handoff_drive_read "$drive"; then
        rm -f "$drive"
        notes+=("autodrive malformed — $DRIVE_ERR; not resuming")
    elif [[ "$DRIVE_STATE" == "pending" && "$DRIVE_KIND" == "clear" ]]; then
        # Only a transition in flight, and only our own kind: a compact armed in
        # the outgoing session is left for SessionStart(compact), and an armed
        # file — one whose Stop never fired — is left for the sweep.
        rm -f "$drive"
```

The body below that `elif` is unchanged. Update the header comment's second
bullet the same way (`.claude/autodrive.pending` → `.claude/autodrive`).

- [ ] **Step 8: Sweep on `armed`**

`scripts/report-watcher-failure.sh`. Replace lines 80-101. The file is parsed
once, up front, because both branches below need its state:

```bash
failed="$cwd/$HANDOFF_REL_DRIVE_FAILED"
drive="$cwd/$HANDOFF_REL_DRIVE"

# Parse once: the failure branch and the sweep want different states of the same
# file. A file that will not parse is recorded as its own value — it describes
# no transition anyone can complete, so the sweep takes it.
drive_state=""
if [[ -f "$drive" ]]; then
    if handoff_drive_read "$drive"; then
        drive_state="$DRIVE_STATE"
    else
        drive_state="malformed"
    fi
fi

if [[ -f "$failed" ]]; then
    reason="$(head -n1 "$failed")"
    rm -f "$failed"
    # A failure part-way through a sequence strands the transition in `pending`:
    # nothing will consume it (its SessionStart never fires) and Stop will not
    # re-arm from that state. Clear it with the report. Only here — a stale
    # armed file says nothing about one in flight, and sweeping on that evidence
    # would race a live SessionStart(compact|clear).
    if [[ "$drive_state" == "pending" ]]; then
        rm -f "$drive"
    fi
    msgs+=("transition watcher did not deliver — $reason")
    notes+=("The handoff transition watcher failed to deliver its line: $reason. The transition or continuation it was driving did not happen, and any lines after it in the sequence were never typed.")
fi

# An autodrive is armed at the Stop of the turn that writes it, and that Stop
# leaves it `pending` or removes it. So one still in state `armed` when a later
# turn begins never armed.
if [[ -n "$drive_state" && "$drive_state" != "pending" ]]; then
    rm -f "$drive"
    msgs+=("stale autodrive discarded — its turn ended without arming")
    notes+=("A .claude/autodrive file was still on disk when this turn began. It is armed at the Stop of the turn that writes it, so one surviving into a later turn never armed — that turn ended on an interrupt, a crash or a quit. It has been discarded, so the transition it described did not happen and cannot fire into unrelated work later.")
fi
```

The header comment's point 2 says "Stop renames or removes it" — that is a
mechanism that no longer exists. Rewrite as "Stop leaves it `pending` or removes
it, so one still in state `armed` when a later turn begins never armed".

- [ ] **Step 9: Write the state line from both writers**

`scripts/checkpoint.sh:254`:

```bash
    printf 'armed\nrename\n/rename %s\n' "$title" > "$root/$HANDOFF_REL_DRIVE"
```

Extend the comment above it: the sentinel now opens with its state, and the
checkpoint's writes are always `armed` — nothing it produces is in flight yet.

`skills/autoname/SKILL.md`, replacing lines 20-26:

```markdown
Then issue a single `Write` to `./.claude/autodrive`, of exactly three lines —
the literal word `armed`, the literal word `rename`, then the rename as it
will be typed:

```
armed
rename
/rename <title>
```

Line 1 is the transition's state. What the agent writes is always `armed`; the
hooks own every state after that.
```

- [ ] **Step 10: Restate the line shapes in the three driven skill bodies**

`skills/handoff-continue/SKILL.md` — "Exactly four lines" becomes five, and each
bullet renumbers:

```markdown
Exactly five lines:

```
armed
clear
/rename <session title>
/clear
<continuation prompt>
```

- **Line 1** — the literal word `armed`, and nothing else. It is the
  transition's state; the hooks own every state after this one.
- **Line 2** — the literal word `clear`, and nothing else. It says which
  transition this is.
- **Line 3** — the rename as it will be typed, carrying the title decided
  in step 3.
- **Line 4** — the literal `/clear`, with no argument.
- **Line 5** — the continuation prompt: one line of prose that resumes the
  work, following the seam rules in `../handoff/SKILL.md`. It must be a
  **single line** — one Enter is one submit, so an embedded newline would
  submit it early.
```

`skills/compact-continue/SKILL.md` — "Exactly three lines" becomes four:

```markdown
Exactly four lines:

```
armed
compact
/compact <focus directive, or nothing>
<continuation prompt>
```

- **Line 1** — the literal word `armed`, and nothing else. It is the
  transition's state; the hooks own every state after this one.
- **Line 2** — the literal word `compact`, and nothing else. It says which
  transition this is.
- **Line 3** — the command as it will be typed: `/compact`, or
  `/compact <directive>` when a focus instruction would help the summariser
  keep the right material.
- **Line 4** — the continuation prompt: one line of prose that resumes the
  work, following the seam rules in `../handoff/SKILL.md`. It must be a
  **single line** — one Enter is one submit, so an embedded newline would
  submit it early.
```

The paragraph that follows the block opens "Author line 3 **silently**" and now
names line 4. Read on past it — anything else in that section citing a line
number shifts by one too.

`skills/precompact/SKILL.md:67-71` — the FR-G marker is two lines now:

```markdown
4. Write `./.claude/autodrive`, containing exactly two lines:

   ```
   armed
   compact
   ```

   Those two words are the whole file: the state the hooks take it from, and
   the transition it describes. Nothing is armed to type; what it records is
   that a compaction is *expected*, which is what the frame's re-injection is
   gated on. Without it the compaction that follows re-injects nothing, and the
   summariser's paraphrase is all that survives of the files just written.
```

- [ ] **Step 11: Run the tests to verify they pass**

Run: `bats tests/hook-test.bats && bats tests/checkpoint.bats`
Expected: all rows PASS.

Then confirm the old name is gone from the code:
`grep -rn 'autodrive\.pending\|DRIVE_PENDING' scripts/ skills/ tests/`
Expected: no matches except `HANDOFF_PENDING_FILE`, which keeps its name — it is
the walker's environment contract, and the walker is unchanged. (`docs/`,
`README.md` and `.gitignore` still match; Task 3 takes those.)

- [ ] **Step 12: Mutation-check the three state gates**

Each gate is a one-line `||` guard, and each has a paired positive over the same
fixture. Take them one at a time — comment the line out, run, restore:

1. `stop-drive.sh`'s `[[ "$DRIVE_STATE" == "armed" ]] || exit 0`.
   Run: `bats tests/hook-test.bats -f stop-drive`
   Expected: *"pending file: ignored, left untouched"* FAILS; *"kind with a
   confirming source: rewrites to pending, reports armed"* still PASSES.
2. `load-compact.sh`'s `pending` conjunct (leave the kind conjunct in place).
   Run: `bats tests/hook-test.bats -f load-compact`
   Expected: *"armed file: not consumed, no frame"* FAILS; *"pending present:
   consumes it and reports the continuation"* still PASSES.
3. `report-watcher-failure.sh`'s `"$drive_state" != "pending"`, changed to a
   bare `-n "$drive_state"`.
   Run: `bats tests/hook-test.bats -f report-watcher-failure`
   Expected: *"pending file: left alone, no report"* FAILS; *"stale autodrive:
   discards it and reports"* still PASSES.

Paste all three mutation runs' `bats` output verbatim into the report for this
task. The rows and the scripts are written in the same pass, so the mutation is
the only thing standing in for a red-phase review — a claim that a row went red
is not the same evidence as the run that did.

If a negative stays green, the row is passing for the wrong reason. Fix the row,
not the script.

- [ ] **Step 13: Commit**

```bash
just precommit
git add scripts/ skills/ tests/
git commit -m "♻️ carry the transition's state in the file, not the filename"
```

Hooks are frozen at session start, so the new gates do not take effect in the
session that lands them. The skill bodies need `/reload-plugins`.

---

### Task 2: The agent's channel writes `armed` only

**Beyond the spec.** The spec has `write-drive.sh` keep validating what the
agent authors, and says nothing about which states the agent may author. Before
this change, a wrong state was unrepresentable: the agent wrote a filename, and
`write-drive.sh` matched exactly one. Collapsing the family turns that into a
content error, and an agent-written `pending` is silently inert — `stop-drive.sh`
ignores it, no loader consumes a kind it does not own, and the sweep exempts
`pending`, so it survives every gate. Two lines close it.

Reject this task and nothing breaks; the hazard needs a skill body to go wrong
first.

**Files:**
- Modify: `scripts/write-drive.sh:25-27`
- Test: `tests/hook-test.bats` (the `write-drive` block, ~705-800)

**Interfaces:**
- Consumes: `DRIVE_STATE` from Task 1.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

Append to the `write-drive` block in `tests/hook-test.bats`:

```bash
# The agent's channel is arm-only. Every state after `armed` is a hook's to
# write, and a `pending` file the agent authored is inert on every gate: Stop
# ignores it, no loader owns its kind, and the sweep exempts pending. It would
# sit there until something overwrote it.
@test "write-drive (agent writes a non-armed state: reported, file survives)" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_write_drive "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage | test("armed")' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.additionalContext | test("Rewrite it now")' >/dev/null
    # Validate only — this hook never deletes, whatever it finds.
    [ -f "$tmp/.claude/autodrive" ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats tests/hook-test.bats -f write-drive`
Expected: the new row FAILS — the hook is silent, so `jq -e` on an empty
`$output` exits non-zero. Every other row in the block stays green.

- [ ] **Step 3: Add the state check**

In `scripts/write-drive.sh`, replace lines 25-27:

```bash
if ! handoff_drive_read "$target"; then
    err="$DRIVE_ERR"
elif [[ "$DRIVE_STATE" != "armed" ]]; then
    # Arm-only: every later state is a hook's to write. The parser accepts them
    # all — which state a caller wants is the caller's business — and this
    # caller is the agent-authored channel.
    err="line 1 must be \`armed\` — every state after that is written by a hook, not by an agent"
else
    exit 0
fi

jq -nc --arg e "$err" '{
```

and change the `jq` invocation's `--arg e "$DRIVE_ERR"` to `--arg e "$err"`.
Both messages below it already read as "malformed — <reason>", and a wrong state
is a malformed file, so neither string needs rewording.

Extend the header comment's last paragraph: the legal shapes are still not
restated here, but the state this channel may write is, because no skill body
owns that rule.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/hook-test.bats -f write-drive`
Expected: all rows PASS, including the pre-existing well-formed rows — the
`seed_drive` helper stamps `armed`, so they must be untouched by this.

- [ ] **Step 5: Commit**

```bash
just precommit
git add scripts/write-drive.sh tests/hook-test.bats
git commit -m "🔒 hold the agent's autodrive channel to the armed state"
```

---

### Task 3: Documentation

**Files:**
- Create: `docs/changelog/2026-08-03-one-transition-one-file.md`
- Modify: `docs/changelog.md` (index line, newest first), `docs/design.md`
  (~216-247, ~466), `README.md` (~122, ~182-188), `CLAUDE.md`, `.gitignore`

**Interfaces:** none.

- [ ] **Step 1: Write the changelog entry**

`docs/changelog/2026-08-03-one-transition-one-file.md`, a write-time record —
never edited afterwards. It must carry: the defect (three filenames are one
object at three points in its life, the machine is spelled out nowhere, and
every consumer reads the point it cares about by choosing a name); the machine
itself (`held → armed → pending → gone`, with `held` arriving in the next pass
and this one leaving room for it); why the state is line 1 rather than a suffix
on the kind line (one fact per line is the file's existing idiom); what does not
change and why — the walker, `.claude/autodrive.failed`, the every-turn fast
path; and the rejected alternatives from the spec, including that routing
`autoname` through the checkpoint is deferred rather than refused. Source the
reasoning from
[the spec](../../plans/2026-08-03-transition-state-machine-design.md). Name
[transitions become modes](../../plans/2026-08-02-transition-modes-design.md)
as what this is preparation for.

If Task 2 landed, record it as an entry-of-its-own paragraph: the state is now
content, so an agent can author a wrong one, and the agent's channel is held to
`armed`.

- [ ] **Step 2: Add the index line**

At the top of the list in `docs/changelog.md`:

```markdown
- [2026-08-03 — One transition, one file, explicit state](changelog/2026-08-03-one-transition-one-file.md) — three filenames were one object at three points in its life; the state becomes a field
```

Append ` (vX.Y.Z)` only once the release lands.

- [ ] **Step 3: Rewrite the `docs/design.md` prose this invalidates**

Two regions, both under the driving-the-TUI material:

1. Lines ~216-247. The sentinel's description ("whose first line is the kind")
   gains the state line; "moving the sentinel to `.pending`" becomes rewriting
   its state in place; "the `.pending` file disappearing for `/compact`" becomes
   the sentinel itself disappearing; "`.claude/autodrive` left by a turn that
   ended on Esc or a crash" becomes one left in state `armed`.
2. Line ~466, the sweep's exemption — "a `.pending` during the whole Stop →
   compaction window" becomes "a file in state `pending`".

Then add one decision under `## Design decisions`:

```markdown
**The transition carries its own state.** There is exactly one transition in
flight at a time, and three filenames were one object at three points in its
life — so every gate read the point it cared about by choosing a name, and the
machine between them existed only as `mv` calls scattered across four hooks.
Line 1 of `.claude/autodrive` is the state and the gates are state checks, which
is the same guarantee stated directly: `Stop` will not re-arm something already
in flight, and the sweep will not take something legitimately mid-window. Adding
a state is now a value, not a filename and four new gates.
[One transition, one file, explicit
state](changelog/2026-08-03-one-transition-one-file.md)
```

- [ ] **Step 4: Update `README.md`**

Line ~122's flow paragraph names `.claude/autodrive` already and needs no
change. The file list at ~182-188 does: the `autodrive` entry gains its state
line, and the "Renamed to `autodrive.pending` when the transition is armed at
the end of the turn" sentence becomes the state rewrite. Keep the entry for
`autodrive.failed` as it is — it is not a state of the transition.

- [ ] **Step 5: Update `CLAUDE.md`**

In the same voice as the surrounding entries, and in the Layout section's
existing order:

- `scripts/_lib.sh` — the `handoff_drive_read` paragraph: line 1 is the state
  and line 2 the kind, the kind still fixes the shape, and the parser reports
  the state without interpreting it. Add `handoff_drive_arm` beside
  `handoff_drive_has_source`, naming the atomicity requirement and the caller it
  is shared with in the next pass. Drop `HANDOFF_REL_DRIVE_PENDING`.
- `scripts/stop-drive.sh` — "`mv` to `.pending` … `rm` for `rename`" becomes the
  state rewrite, and the gate on `armed` is what the consume-before-spawn
  sentence now says directly.
- `scripts/load-compact.sh` and the `SessionStart(startup|clear)` entry — each
  consumes only its own kind **in state `pending`**.
- `scripts/report-watcher-failure.sh` — the sweep keys on `armed`; a file in
  `pending` is exempt for the whole window.
- `scripts/write-drive.sh` — if Task 2 landed, that it also holds the channel to
  `armed`.
- The Testing section — the state-gate rows and which three are
  mutation-checked.

- [ ] **Step 6: Fix the `.gitignore` comment**

The `.claude/autodrive*` block's comment names "its siblings (.pending,
.failed)". There is one sibling now, plus the `.arming.$$` temp the atomic
rewrite lands beside it. Say that.

- [ ] **Step 7: Commit**

```bash
just precommit
git add docs/ README.md CLAUDE.md .gitignore
git commit -m "📝 record the transition state machine"
```

---

## After the plan

A patch release: no user-visible file changes shape (`handoff-task.md` and
`handoff-todo.md` are untouched), and `.claude/autodrive` is transient — it
exists for part of one turn and is gitignored. The skill bodies change, but what
they name and when to invoke them does not.

Release is `just release`; it owns the version bump, and `version-guard.sh`
denies an agent edit to `plugin.json`'s `.version`, so no task here touches it.
It can ride with the context-threshold release rather than going out alone.

Then dogfood, which needs a restart to pick up the changed hooks and a
`/reload-plugins` for the skills. The path worth exercising by hand is the one
no test reaches: an actual driven `/clear`, where the walker types two lines
across a real turn boundary and `submit_consumed` waits on a file that is now
rewritten rather than renamed.

`transitions become modes` follows. It writes `held` into the state field this
pass built, widens `handoff_drive_read` to accept it, and adds
`handoff-approved` on top of `handoff_drive_arm`.
