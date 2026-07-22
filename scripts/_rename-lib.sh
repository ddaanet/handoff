#!/usr/bin/env bash
# shellcheck shell=bash
# Shared machinery for every detached watcher (*-when-idle.sh): pure
# predicates over captured tmux pane text (read stdin), the pane-polling
# scaffold (snap / wait_for_idle / submit_or_fail, which expect the sourcing
# watcher to have set PANE), and the shared tunables. Do not execute directly.
# shellcheck disable=SC2034  # consumed by sourcing scripts

# Tunables (overridden by the tests for speed).
TIMEOUT="${HANDOFF_WATCHER_TIMEOUT:-30}"
POLL="${HANDOFF_WATCHER_POLL:-0.1}"
VERIFY_DELAY="${HANDOFF_WATCHER_VERIFY_DELAY:-0.5}"

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

# Enter, then confirm the turn actually started; retry the Enter only —
# re-sending the text would concatenate a second copy. Keyed on is_busy, not
# is_typing: an Enter absorbed as a line break (the TUI's paste window) leaves
# a multi-line composer whose last ❯ line reads empty, faking a successful
# submit. Terminates the watcher either way — exit 0 on a confirmed submit,
# watcher_fail with $1 after three misses — so only safe as a watcher's final
# statement.
#
# Used by the compact watcher (line 1). Its `/compact` is typed at Stop, when
# the session is idle, and submitting it starts the compaction — a long,
# reliably-busy operation. So is_busy confirms it within the window. The
# continuation watcher (line 2) cannot use this: see submit_confirmed_or_fail.
submit_or_fail() {
    for _ in 1 2 3; do
        tmux send-keys -t "$PANE" Enter
        sleep "$VERIFY_DELAY"
        snap | is_busy && exit 0
    done
    watcher_fail "$1"
}

# Count genuine user-prompt entries in the transcript ($1) whose decoded text
# contains the marker ($2). "Genuine" excludes the harness-injected user entries
# — the isMeta frame, the isCompactSummary, a sidechain — so only a real
# submitted prompt counts. The task text is typically all over the transcript
# (compact summary, injected frame, attachments), so a raw substring grep would
# false-match; keying on the entry's structural flags is the same discipline as
# handoff_activated. Prints an integer; 0 (never an error) on an empty/unset or
# unreadable path. The format is undocumented — flags, not content heuristics.
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

# Confirm the just-typed prompt was ACCEPTED into the session — not that a turn
# is visibly running. A submit made while the session is still settling after a
# compaction is queued: accepted at once, but its spinner appears only when the
# queued turn starts, ~13s later in the field (session 8e39f620). is_busy times
# that spinner and so false-fails on a queued submit; the transcript records the
# accepted prompt as a user entry immediately, which is the signal here.
#
# $1 = marker (the typed line, matched verbatim as a substring), $2 = failure
# reason. Baseline the count before the first Enter, then Enter/poll up to three
# times: the first Enter can be absorbed into the paste window as a newline, and
# a later Enter submits the resulting multi-line composer — the same prose, so a
# retry that lands is still a success. Terminates the watcher — exit 0 once a new
# matching entry appears, watcher_fail with $2 otherwise — so only safe as a
# watcher's final statement.
submit_confirmed_or_fail() {
    local marker="$1" reason="$2" baseline
    baseline="$(transcript_prompt_count "${HANDOFF_TRANSCRIPT:-}" "$marker")"
    for _ in 1 2 3; do
        tmux send-keys -t "$PANE" Enter
        sleep "$VERIFY_DELAY"
        (( "$(transcript_prompt_count "${HANDOFF_TRANSCRIPT:-}" "$marker")" > baseline )) && exit 0
    done
    watcher_fail "$reason"
}

# Record a non-delivery, then exit 1. Watchers run detached: nothing reads their
# exit status, so a line that never lands is otherwise invisible — worst of all
# on the compact watcher's C-u abort, which also wipes the composer and leaves
# the pane looking untouched. The reason goes in $HANDOFF_FAIL_FILE (set by the
# spawning hook, which owns the path) for report-compact-failure.sh to surface at
# the next UserPromptSubmit. Unset is tolerated: recording is additive, never a
# precondition for driving the pane.
watcher_fail() {
    [ -n "${HANDOFF_FAIL_FILE:-}" ] && printf '%s\n' "$1" > "$HANDOFF_FAIL_FILE"
    exit 1
}
