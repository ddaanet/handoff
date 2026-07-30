#!/usr/bin/env bash
# shellcheck shell=bash
# Shared machinery for drive-when-idle.sh, the one detached watcher: pure
# predicates over captured tmux pane text (read stdin), the pane-polling
# scaffold (snap / wait_for_idle / the three submit confirmations, which expect
# the sourcing watcher to have set PANE), and the shared tunables. Do not
# execute directly.
# shellcheck disable=SC2034  # consumed by sourcing scripts

# Tunables (overridden by the tests for speed).
TIMEOUT="${HANDOFF_WATCHER_TIMEOUT:-30}"
POLL="${HANDOFF_WATCHER_POLL:-0.1}"
VERIFY_DELAY="${HANDOFF_WATCHER_VERIFY_DELAY:-0.5}"
# A compaction is minutes-scale work, so its confirmation gets its own budget
# and its own unhurried poll.
CONSUME_TIMEOUT="${HANDOFF_WATCHER_CONSUME_TIMEOUT:-300}"
CONSUME_POLL="${HANDOFF_WATCHER_CONSUME_POLL:-1}"

# Strip ANSI escapes and carriage returns. BSD/macOS sed honors neither
# \x1B nor \r in a script, so feed sed a literal ESC (bash ANSI-C quote,
# octal for bash 3.2) and delete CRs with tr (which does grok \r everywhere).
strip() { sed -E $'s/\033\\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'; }

# Busy while the Claude TUI chrome spinner is on screen: timer reads
# "(<n>s ·" or the "esc to interrupt" hint is visible.
is_busy() { strip | grep -Eq '\([0-9]+s ·|esc to interrupt'; }

# Typing: the last "❯" prompt line has non-space content — user is composing.
is_typing() { strip | grep -E '❯' | tail -n1 | grep -Eq '❯[[:space:]]+[^[:space:]]'; }

# A slash command typed with no Enter renders either an autocomplete row for
# the command or `No commands match "…"`. True on the latter: the composer holds
# something the TUI will not run, so Enter must never follow.
is_unknown_command() { strip | grep -Fq 'No commands match'; }

# Read only the VISIBLE pane, never `capture-pane -S` history: a stale timer
# glyph in scrollback matches is_busy long after the turn ended (spike,
# 2026-07-19). $PANE is set by the sourcing watcher.
# shellcheck disable=SC2154
snap() { tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 40; }

# Wait until idle has been stable for ~3 consecutive polls, up to TIMEOUT.
# Falls through on timeout — the caller's is_typing check is the real gate
# against typing over a live composer.
wait_for_idle() {
    local deadline=$((SECONDS + TIMEOUT)) stable=0
    while (( SECONDS < deadline )); do
        if snap | is_busy; then stable=0; sleep "$POLL"; continue; fi
        stable=$((stable + 1))
        (( stable >= 3 )) && break
        sleep "$POLL"
    done
    return 0
}

# Enter, then wait for the caller's check ($@, run as a command) to pass. Retry
# the Enter three times at VERIFY_DELAY — the first can be absorbed into the
# TUI's paste window as a line break, and a later one submits the resulting
# multi-line composer, which is the same text and so still a success — then poll
# on without resending, since re-sending the text would concatenate a second
# copy and a registered Enter can take far longer than VERIFY_DELAY to show in
# the signal (observed live 2026-07-24: an 18s gap between a compaction's
# summary being ready and its boundary landing in the transcript).
#
# Returns 0 confirmed, 1 timed out. The cost of the long phase is latency — a
# genuine non-delivery is reported one CONSUME_TIMEOUT late rather than at once.
# That is the right trade: the report surfaces at the next UserPromptSubmit
# either way, and a false alarm is worse than a slow one.
_submit_until() {
    local deadline
    for _ in 1 2 3; do
        tmux send-keys -t "$PANE" Enter
        sleep "$VERIFY_DELAY"
        "$@" && return 0
    done
    deadline=$((SECONDS + CONSUME_TIMEOUT))
    while (( SECONDS < deadline )); do
        "$@" && return 0
        sleep "$CONSUME_POLL"
    done
    return 1
}

# The three confirmation primitives, one per command class. Each submits the
# line already typed into the composer and answers whether the harness recorded
# it — none reads the pane, and none terminates the watcher: the walker owns
# failure for the whole sequence and calls watcher_fail once (see
# docs/design.md, "Confirmation dispatches on the command").

# /compact and /clear: the transition's own SessionStart consumes
# $HANDOFF_PENDING_FILE, so its disappearance is the authoritative signal that
# the transition happened. is_busy was the original criterion and false-fails
# here — on 2026-07-22 a live `/compact` submitted, compacted for 103s, and was
# still reported as never submitted, because the TUI shows no chrome is_busy
# matches in the ~1.5s after the keystroke. is_typing is no better: an Enter
# absorbed as a line break leaves a multi-line composer whose last ❯ line reads
# empty, faking a successful submit. With no file to confirm against, submit and
# report success: an unconfirmable submit is not a failed one.
submit_consumed() {
    local pending="${HANDOFF_PENDING_FILE:-}"
    if [ -z "$pending" ]; then
        tmux send-keys -t "$PANE" Enter
        return 0
    fi
    _submit_until _pending_gone "$pending"
}
_pending_gone() { [ ! -e "$1" ]; }

# Count genuine user-prompt entries in the transcript ($1) whose decoded text
# contains the marker ($2). "Genuine" excludes the harness-injected user entries
# — the isMeta frame, the isCompactSummary, a sidechain — so only a real
# submitted prompt counts. The task text is typically all over the transcript
# (compact summary, injected frame, attachments), so a raw substring grep would
# false-match; keying on the entry's structural flags (isMeta, isCompactSummary,
# isSidechain) rather than content is the discipline this whole file follows.
# Prints an integer; 0 (never an error) on an empty/unset or unreadable path.
# The format is undocumented — flags, not content heuristics.
transcript_prompt_count() {
    local transcript="$1" marker="$2"
    [[ -n "$transcript" && -f "$transcript" ]] || { printf '0\n'; return 0; }
    python3 - "$transcript" "$marker" <<'PY'
import json, sys
path, marker = sys.argv[1], sys.argv[2]
n = 0
try:
    fh = open(path, encoding="utf-8", errors="replace")
except OSError:
    print(0); sys.exit(0)
with fh:
    for line in fh:
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("type") != "user":
            continue
        if e.get("isMeta") or e.get("isCompactSummary") or e.get("isSidechain"):
            continue
        msg = e.get("message") or {}
        c = msg.get("content")
        if isinstance(c, list):
            c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
        if isinstance(c, str) and marker in c:
            n += 1
print(n)
PY
}

# Count session-title entries in the transcript ($1) whose customTitle is
# EXACTLY the title ($2). `/rename <t>`, the `-n` flag and ctrl+R all write
# `{"type":"custom-title","customTitle":"<t>"}`; the harness's own auto-titling
# writes `type: "ai-title"`, a distinct type, so an exact match here cannot
# false-positive on it. This is the FR-F primitive that retires the last
# pane-reading confirmation — the old rename watcher grepped the pane for the
# title's first 20 characters, which matches whenever the title is on screen for
# any other reason (the composer's own echo, the reply naming the title it
# chose). Prints an integer; 0 (never an error) on an empty/unset or unreadable
# path.
transcript_title_count() {
    local transcript="$1" title="$2"
    [[ -n "$transcript" && -f "$transcript" ]] || { printf '0\n'; return 0; }
    python3 - "$transcript" "$title" <<'PY'
import json, sys
path, title = sys.argv[1], sys.argv[2]
n = 0
try:
    fh = open(path, encoding="utf-8", errors="replace")
except OSError:
    print(0); sys.exit(0)
with fh:
    for line in fh:
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("type") == "custom-title" and e.get("customTitle") == title:
            n += 1
print(n)
PY
}

# /rename <title>: a custom-title entry carrying exactly that title.
submit_titled() {
    local title="$1" baseline
    baseline="$(transcript_title_count "${HANDOFF_TRANSCRIPT:-}" "$title")"
    _submit_until _title_grew "$title" "$baseline"
}
_title_grew() {
    (( "$(transcript_title_count "${HANDOFF_TRANSCRIPT:-}" "$1")" > $2 ))
}

# Prose: the prompt was ACCEPTED into the session — not that a turn is visibly
# running. A submit made while the session is still settling after a compaction
# is queued: accepted at once, but its spinner appears only when the queued turn
# starts, ~13s later in the field (session 8e39f620). is_busy times that spinner
# and so false-fails on a queued submit; the transcript records the accepted
# prompt as a user entry immediately, which is the signal here. The baseline is
# taken before the first Enter, so a stale pre-transition copy of the same line
# does not read as a submit.
submit_prompted() {
    local marker="$1" baseline
    baseline="$(transcript_prompt_count "${HANDOFF_TRANSCRIPT:-}" "$marker")"
    _submit_until _prompt_grew "$marker" "$baseline"
}
_prompt_grew() {
    (( "$(transcript_prompt_count "${HANDOFF_TRANSCRIPT:-}" "$1")" > $2 ))
}

# Record a non-delivery, then exit 1. The walker runs detached: nothing reads its
# exit status, so a line that never lands is otherwise invisible — worst of all
# on the recognition abort, which also wipes the composer and leaves the pane
# looking untouched. The reason goes in $HANDOFF_FAIL_FILE (set by the
# spawning hook, which owns the path) for report-watcher-failure.sh to surface at
# the next UserPromptSubmit. Unset is tolerated: recording is additive, never a
# precondition for driving the pane.
watcher_fail() {
    [ -n "${HANDOFF_FAIL_FILE:-}" ] && printf '%s\n' "$1" > "$HANDOFF_FAIL_FILE"
    exit 1
}
