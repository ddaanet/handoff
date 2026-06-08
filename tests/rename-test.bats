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
