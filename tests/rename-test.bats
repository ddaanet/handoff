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

    run env PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=5 AUTONAME_POLL=0.01 AUTONAME_VERIFY_DELAY=0.01 \
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

    PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=1 AUTONAME_POLL=0.01 \
        bash "$SCRIPTS/rename-when-idle.sh" '%9' 'Should Not Send' >/dev/null 2>&1

    [ ! -s "$SENT" ]
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
make_compact_stub() {
    SENT="$STUBDIR/sent.log"; : > "$SENT"
    STATE_L="$STUBDIR/sent_l"; STATE_E="$STUBDIR/sent_enter"
    rm -f "$STATE_L" "$STATE_E"
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane)
    if [ -f "$STATE_E" ]; then printf '%s\n' '  ⎿  Compacted (312 messages)' '❯ '
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
    run env PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=5 AUTONAME_POLL=0.01 \
        AUTONAME_VERIFY_DELAY=0.01 \
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
    run env PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=5 AUTONAME_POLL=0.01 \
        AUTONAME_VERIFY_DELAY=0.01 \
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

    PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=1 AUTONAME_POLL=0.01 \
        bash "$SCRIPTS/compact-when-idle.sh" '%9' '/compact' >/dev/null 2>&1

    [ ! -s "$SENT" ]
}

# --- continue-when-idle.sh (line 2: prose, no recognition check) ---------------

@test "continue watcher types the prompt literally then Enters" {
    SENT="$STUBDIR/sent.log"; COUNT="$STUBDIR/count"
    echo 0 > "$COUNT"; : > "$SENT"
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane)
    n=\$(cat "$COUNT"); n=\$((n + 1)); echo "\$n" > "$COUNT"
    printf '%s\n' '──── x ──' '❯ ' ;;
  send-keys) printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT" ;;
esac
STUB
    chmod +x "$STUBDIR/tmux"

    run env PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=5 AUTONAME_POLL=0.01 \
        AUTONAME_VERIFY_DELAY=0.01 \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'continue with task 3'
    [ "$status" -eq 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"-l|continue with task 3|"* ]]
    [[ "$sent" == *"Enter|"* ]]
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

    PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=1 AUTONAME_POLL=0.01 \
        bash "$SCRIPTS/continue-when-idle.sh" '%9' 'should not send' >/dev/null 2>&1

    [ ! -s "$SENT" ]
}
