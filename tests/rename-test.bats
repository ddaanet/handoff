#!/usr/bin/env bats
# Test suite for the rename (session-title) scripts.
#
# Covers the pure predicates (_rename-lib.sh) and the rename-when-idle.sh
# watcher end-to-end against a tmux stub on PATH (no real tmux/Claude
# needed). Migrated from tests/rename-test.sh.
#
# Run with: bats tests/rename-test.bats   (from plugin root)

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPTS="$ROOT/scripts"

    # Sample captured pane text.
    busy_text=$'  ⎿  running\n* Flummoxing… (37s · ↓ 2.4k tokens)\n──── name pending ──\n❯ \n────'
    idle_text=$'  ⎿  done\n──── name pending ──\n❯ \n────\n  ▄▂▁15s│3m▅▆ 15:30 / 7d Wed 12:42'
    typing_text=$'──── name pending ──\n❯ hello there\n────'

    # shellcheck source-path=SCRIPTDIR source=../scripts/_rename-lib.sh disable=SC1091
    . "$SCRIPTS/_rename-lib.sh"

    STUBDIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUBDIR"
}

# --- _rename-lib.sh predicates -------------------------------------------------
# is_busy / is_typing read captured pane text on stdin and exit 0/1.

@test "is_busy true on spinner text" {
    run is_busy <<< "$busy_text"
    [ "$status" -eq 0 ]
}

@test "is_busy false on idle text" {
    run is_busy <<< "$idle_text"
    [ "$status" -ne 0 ]
}

@test "is_typing true on non-empty prompt" {
    run is_typing <<< "$typing_text"
    [ "$status" -eq 0 ]
}

@test "is_typing false on empty prompt" {
    run is_typing <<< "$idle_text"
    [ "$status" -ne 0 ]
}

# --- transcript_prompt_count ---------------------------------------------------
# The queued-submit signal: a genuine user-prompt entry whose text contains the
# marker. is_busy times the spinner and false-fails on a queued submit whose turn
# starts seconds later; the transcript records the accepted prompt at once. This
# helper counts only real submissions — harness-injected user entries (isMeta
# frame, isCompactSummary) and assistant echoes must not count, or a prompt that
# is merely *quoted* in the summary would read as submitted.

MARKER='run code-review per the task file'

# Write one JSONL entry: <type> <flags-json-fragment-or-empty> <content>.
tp_entry() {
    local type="$1" extra="$2" content="$3"
    if [ "$type" = assistant ]; then
        printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$content"
    else
        printf '{"type":"%s"%s,"message":{"role":"user","content":"%s"}}\n' "$type" "$extra" "$content"
    fi
}

@test "transcript_prompt_count: 0 for a missing transcript" {
    run transcript_prompt_count "$BATS_TEST_TMPDIR/nope.jsonl" "$MARKER"
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
}

@test "transcript_prompt_count: 0 for an empty/unset path" {
    run transcript_prompt_count "" "$MARKER"
    [ "$output" = 0 ]
}

@test "transcript_prompt_count: counts a genuine user prompt containing the marker" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    tp_entry user "" "please $MARKER now" > "$tr"
    run transcript_prompt_count "$tr" "$MARKER"
    [ "$output" = 1 ]
}

@test "transcript_prompt_count: ignores isMeta, isCompactSummary, and assistant echoes" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    {
        tp_entry user ',"isMeta":true'          "frame quoting $MARKER"
        tp_entry user ',"isCompactSummary":true' "summary quoting $MARKER"
        tp_entry assistant ""                    "I will $MARKER"
    } > "$tr"
    run transcript_prompt_count "$tr" "$MARKER"
    [ "$output" = 0 ]
}

@test "transcript_prompt_count: does not match a non-containing prompt" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    tp_entry user "" "something else entirely" > "$tr"
    run transcript_prompt_count "$tr" "$MARKER"
    [ "$output" = 0 ]
}

# --- rename-when-idle.sh end-to-end via a tmux stub ----------------------------

@test "watcher sends /rename with title (-l) then a separate Enter, exits 0 after verify" {
    SENT="$STUBDIR/sent.log"; COUNT="$STUBDIR/count"
    echo 0 > "$COUNT"; : > "$SENT"

    # Stub emits "busy" for the first 2 captures, then idle with the title
    # shown (as the status bar would read after a successful rename).
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane)
    n=\$(cat "$COUNT"); n=\$((n + 1)); echo "\$n" > "$COUNT"
    if (( n <= 2 )); then
      printf '%s\n' '* Flummoxing… (12s · ↓ 1k tokens)' '❯ '
    else
      printf '%s\n' '──── Demo Title Here ──' '❯ '
    fi ;;
  send-keys)
    printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT" ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"

    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 HANDOFF_WATCHER_VERIFY_DELAY=0.01 \
        bash "$SCRIPTS/rename-when-idle.sh" '%9' 'Demo Title Here'
    [ "$status" -eq 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"-l|/rename Demo Title Here|"* ]]
    [[ "$sent" == *"Enter|"* ]]
}

@test "watcher sends nothing while user types" {
    SENT="$STUBDIR/sent.log"
    : > "$SENT"

    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane) printf '%s\n' '──── x ──' '❯ user is typing' ;;
  send-keys) printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT" ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"

    fail_file="$BATS_TEST_TMPDIR/autorename.failed"
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=1 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/rename-when-idle.sh" '%9' 'Should Not Send'

    [ ! -s "$SENT" ]
    # The bail is a non-delivery like any other. It used to exit 0 — the exact
    # shape DESIGN.md calls indistinguishable from success.
    [ "$status" -ne 0 ]
    grep -qi 'composing' "$fail_file"
}

@test "watcher records a rename that never took" {
    SENT="$STUBDIR/sent.log"
    : > "$SENT"

    # Idle and empty, but the title never appears: the rename did not land.
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane) printf '%s\n' '──── x ──' '❯ ' ;;
  send-keys) printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT" ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"

    fail_file="$BATS_TEST_TMPDIR/autorename.failed"
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=1 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/rename-when-idle.sh" '%9' 'Demo Title Here'

    [ "$status" -ne 0 ]
    grep -q 'Demo Title Here' "$fail_file"
}

# --- _rename-lib.sh: command-recognition predicate -----------------------------
# After a slash command is typed with no Enter, the TUI renders either an
# autocomplete row for the command or `No commands match "…"`. The compact
# watcher checks this before pressing Enter — see DESIGN.md, type-verify-submit.

@test "is_unknown_command true on 'No commands match'" {
    run is_unknown_command <<< $'No commands match "/compzzz"\n❯ /compzzz'
    [ "$status" -eq 0 ]
}

@test "is_unknown_command false on an autocomplete row" {
    run is_unknown_command <<< $'/compact  Compact the conversation\n❯ /compact'
    [ "$status" -ne 0 ]
}

@test "is_unknown_command false on plain idle text" {
    run is_unknown_command <<< "$idle_text"
    [ "$status" -ne 0 ]
}

# --- compact-when-idle.sh (line 1: type-verify-submit) -------------------------

# tmux stub whose capture-pane output depends on what has been sent so far.
# $1 = pane text to render after the literal send (recognized vs not).
# $2 = pane text to render after the Enter; defaults to busy chrome. The real
#      TUI does not reliably show any within the confirm window — that is the
#      whole reason line 1 no longer keys on it — so tests that exercise the
#      confirmation pass a quiet pane here.
make_compact_stub() {
    SENT="$STUBDIR/sent.log"; : > "$SENT"
    STATE_L="$STUBDIR/sent_l"; STATE_E="$STUBDIR/sent_enter"
    rm -f "$STATE_L" "$STATE_E"
    local after_enter="${2:-"'✻ Compacting… (3s · esc to interrupt)' '❯ '"}"
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane)
    if [ -f "$STATE_E" ]; then printf '%s\n' $after_enter
    elif [ -f "$STATE_L" ]; then printf '%s\n' $1 '❯ /compact'
    else printf '%s\n' '──── x ──' '❯ '
    fi ;;
  send-keys)
    printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT"
    case "\$*" in
      *Enter*) touch "$STATE_E" ;;
      *-l*)    touch "$STATE_L" ;;
    esac ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"
}

@test "compact watcher types line 1 literally, verifies recognition, then Enters" {
    make_compact_stub "'/compact  Compact the conversation'"
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compact keep the parser work'
    [ "$status" -eq 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"-l|/compact keep the parser work|"* ]]
    [[ "$sent" == *"Enter|"* ]]
    # The literal send must precede Enter — recognition is checked in between.
    l_line=$(grep -n -- '-l|' "$SENT" | head -1 | cut -d: -f1)
    e_line=$(grep -n 'Enter|' "$SENT" | head -1 | cut -d: -f1)
    [ "$l_line" -lt "$e_line" ]
}

@test "compact watcher aborts on an unrecognized command: C-u, never Enter" {
    make_compact_stub "'No commands match \"/compzzz\"'"
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compzzz'
    [ "$status" -ne 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"C-u|"* ]]
    [[ "$sent" != *"Enter|"* ]]
}

@test "compact watcher sends nothing while user types" {
    SENT="$STUBDIR/sent.log"; : > "$SENT"
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane) printf '%s\n' '──── x ──' '❯ half-typed thought' ;;
  send-keys) printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT" ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"

    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=1 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compact'

    # A bail is a non-delivery like any other: the line never lands, so it is
    # reported rather than exiting 0 as it used to.
    [ "$status" -ne 0 ]
    [ ! -s "$SENT" ]
    grep -qi 'composing' "$fail_file"
}

# Confirming line 1. Submitting `/compact` starts a compaction, but the TUI
# shows no chrome is_busy matches within the confirm window — observed live
# 2026-07-22, where the compaction ran for 103s and the watcher still reported
# "three Enters did not submit it". The authoritative signal is the one
# SessionStart(compact) acts on: it consumes .claude/autocompact.pending. So the
# watcher waits for that file to go, and never guesses from the pane.

# A quiet pane after Enter: no spinner, no timer, empty composer.
QUIET_AFTER_ENTER="'──── x ──' '❯ '"

@test "compact watcher confirms line 1 by the pending file being consumed" {
    make_compact_stub "'/compact  Compact the conversation'" "$QUIET_AFTER_ENTER"
    pending="$BATS_TEST_TMPDIR/autocompact.pending"
    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"
    : > "$pending"
    # Stand in for SessionStart(compact), which consumes the file when the
    # compaction completes — well after any pane-chrome window would close.
    ( sleep 0.3; rm -f "$pending" ) &

    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_WATCHER_CONSUME_POLL=0.05 \
        HANDOFF_WATCHER_CONSUME_TIMEOUT=5 \
        HANDOFF_PENDING_FILE="$pending" HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compact keep the parser work'
    [ "$status" -eq 0 ]
    [ ! -e "$fail_file" ]
}

@test "compact watcher reports line 1 when no compaction ever consumes it" {
    make_compact_stub "'/compact  Compact the conversation'" "$QUIET_AFTER_ENTER"
    pending="$BATS_TEST_TMPDIR/autocompact.pending"
    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"
    : > "$pending"

    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_WATCHER_CONSUME_POLL=0.05 \
        HANDOFF_WATCHER_CONSUME_TIMEOUT=1 \
        HANDOFF_PENDING_FILE="$pending" HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compact keep the parser work'
    [ "$status" -ne 0 ]
    grep -qi 'no compaction' "$fail_file"
}

# Recording a failure is additive, never a precondition — and an unconfirmable
# submit must not be reported as a failed one.
@test "compact watcher stays silent when there is nothing to confirm against" {
    make_compact_stub "'/compact  Compact the conversation'" "$QUIET_AFTER_ENTER"
    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"

    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_WATCHER_CONSUME_TIMEOUT=1 \
        HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compact'
    [ "$status" -eq 0 ]
    [ ! -e "$fail_file" ]
}

# --- continue-when-idle.sh (line 2: prose, no recognition check) ---------------

# tmux stub for the continue watcher. $1 = "submits" (the Enter is accepted —
# the harness appends the prompt to the transcript) or "absorbs" (the Enter lands
# inside the TUI's paste window and becomes a literal newline — nothing is
# submitted, the transcript does not grow). The pane is ALWAYS idle with an empty
# composer: a queued submit shows no spinner even on success, so the transcript,
# not the pane, is the confirmation signal (submit_confirmed_or_fail). The
# transcript is seeded with a stale pre-compaction copy of the same prompt, so a
# passing confirmation must detect a NEW entry, not the marker's mere presence.
make_continue_stub() {
    SENT="$STUBDIR/sent.log"; : > "$SENT"
    TRANSCRIPT="$STUBDIR/transcript.jsonl"
    printf '{"type":"user","message":{"role":"user","content":"continue with task 3 (stale pre-compact copy)"}}\n' \
        > "$TRANSCRIPT"
    local mode="$1"
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane) printf '%s\n' '──── x ──' '❯ ' ;;
  send-keys)
    printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT"
    case "\$*" in *Enter*)
      [ "$mode" = submits ] && \
        printf '{"type":"user","message":{"role":"user","content":"continue with task 3"}}\n' >> "$TRANSCRIPT"
      ;; esac ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"
}

# Regression (session 8e39f620): the accepted continuation was queued behind
# post-compaction settling, so no spinner showed in the confirm window and the
# is_busy check reported non-delivery for a line that arrived. The pane here
# never goes busy, yet the transcript gains the entry — confirmation must pass.
@test "continue watcher confirms a queued submit that shows no spinner" {
    make_continue_stub submits
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_TRANSCRIPT="$TRANSCRIPT" \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'continue with task 3'
    [ "$status" -eq 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"-l|continue with task 3|"* ]]
    # Exactly one Enter: the transcript gained the entry on the first submit.
    [ "$(grep -c 'Enter|' "$SENT")" -eq 1 ]
}

# The other side: the Enter is absorbed, no transcript entry ever appears, so the
# watcher retries three times and then reports non-delivery.
@test "continue watcher retries and fails when the Enter is absorbed" {
    make_continue_stub absorbs
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_TRANSCRIPT="$TRANSCRIPT" \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'continue with task 3'
    [ "$status" -ne 0 ]

    sent="$(cat "$SENT")"
    [ "$(grep -c 'Enter|' "$SENT")" -eq 3 ]
    # The text is never re-sent — that would concatenate a second copy.
    [ "$(grep -c -- '-l|' "$SENT")" -eq 1 ]
}

@test "continue watcher sends nothing while user types" {
    SENT="$STUBDIR/sent.log"; : > "$SENT"
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane) printf '%s\n' '──── x ──' '❯ half-typed thought' ;;
  send-keys) printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT" ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"

    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=1 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'should not send'

    [ "$status" -ne 0 ]
    [ ! -s "$SENT" ]
    grep -qi 'composing' "$fail_file"
}

# --- non-delivery is recorded (watchers are detached; exit status goes nowhere) -

@test "continue watcher records the failure when the Enter is absorbed" {
    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"
    make_continue_stub absorbs
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_TRANSCRIPT="$TRANSCRIPT" \
        HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'continue with task 3'
    [ "$status" -ne 0 ]

    [ -s "$fail_file" ]
    grep -qi 'continuation' "$fail_file"
}

@test "continue watcher records nothing on a confirmed submit" {
    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"
    make_continue_stub submits
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_TRANSCRIPT="$TRANSCRIPT" \
        HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'continue with task 3'
    [ "$status" -eq 0 ]

    [ ! -e "$fail_file" ]
}

@test "compact watcher records the failure on an unrecognized command" {
    fail_file="$BATS_TEST_TMPDIR/autocompact.failed"
    make_compact_stub "'No commands match \"/compzzz\"'"
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_FAIL_FILE="$fail_file" \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compzzz'
    [ "$status" -ne 0 ]

    [ -s "$fail_file" ]
    grep -qi 'recognize' "$fail_file"
}

# Without a fail file configured the watcher must still behave — the recording is
# additive, never a precondition for driving the pane.
@test "watcher tolerates an unset HANDOFF_FAIL_FILE" {
    make_continue_stub absorbs
    run env PATH="$STUBDIR:$PATH" HANDOFF_WATCHER_TIMEOUT=5 HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_TRANSCRIPT="$TRANSCRIPT" \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'continue with task 3'
    [ "$status" -ne 0 ]
}
