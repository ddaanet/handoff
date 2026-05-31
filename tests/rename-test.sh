#!/usr/bin/env bash
# Test suite for the rename (session-title) scripts.
#
# Covers the pure predicates (_rename-lib.sh), the set-title.sh branches
# (no title / not-in-tmux), and the rename-when-idle.sh watcher end-to-end
# against a tmux stub on PATH (no real tmux/Claude needed).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
fails=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# --- Sample captured pane text -------------------------------------------------
busy_text=$'  ⎿  running\n* Flummoxing… (37s · ↓ 2.4k tokens)\n──── name pending ──\n❯ \n────'
idle_text=$'  ⎿  done\n──── name pending ──\n❯ \n────\n  ▄▂▁15s│3m▅▆ 15:30 / 7d Wed 12:42'
typing_text=$'──── name pending ──\n❯ hello there\n────'

# --- _rename-lib.sh predicates -------------------------------------------------
# shellcheck source=scripts/_rename-lib.sh
. "$SCRIPTS/_rename-lib.sh"

if printf '%s' "$busy_text" | is_busy; then pass "is_busy true on spinner text"
else fail "is_busy true on spinner text"; fi

if printf '%s' "$idle_text" | is_busy; then fail "is_busy false on idle text"
else pass "is_busy false on idle text"; fi

if printf '%s' "$typing_text" | is_typing; then pass "is_typing true on non-empty prompt"
else fail "is_typing true on non-empty prompt"; fi

if printf '%s' "$idle_text" | is_typing; then fail "is_typing false on empty prompt"
else pass "is_typing false on empty prompt"; fi

# --- set-title.sh: missing title -> exit 2 -------------------------------------
bash "$SCRIPTS/set-title.sh" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then pass "no title exits 2"; else fail "no title exits 2 (rc=$rc)"; fi

bash "$SCRIPTS/set-title.sh" '   ' >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then pass "whitespace-only title exits 2"; else fail "whitespace-only title exits 2 (rc=$rc)"; fi

# --- set-title.sh: not in tmux -> paste fallback -------------------------------
out="$(env -u TMUX -u TMUX_PANE bash "$SCRIPTS/set-title.sh" 'My Title' 2>&1)"
if [[ "$out" == *"/rename My Title"* ]]; then pass "fallback prints the /rename line"
else fail "fallback prints the /rename line"; fi
if [[ "$out" == *tmux* ]]; then pass "fallback mentions tmux"; else fail "fallback mentions tmux"; fi

# --- rename-when-idle.sh end-to-end via a tmux stub ----------------------------
STUBDIR="$(mktemp -d)"; trap 'rm -rf "$STUBDIR"' EXIT
SENT="$STUBDIR/sent.log"; COUNT="$STUBDIR/count"
echo 0 > "$COUNT"; : > "$SENT"

# Stub emits "busy" for the first 2 captures, then idle with the title shown
# (as the status bar would read after a successful rename).
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

PATH="$STUBDIR:$PATH" AUTONAME_TIMEOUT=5 AUTONAME_POLL=0.01 AUTONAME_VERIFY_DELAY=0.01 \
    bash "$SCRIPTS/rename-when-idle.sh" '%9' 'Demo Title Here'; rc=$?
sent="$(cat "$SENT")"

if [[ $rc -eq 0 ]]; then pass "watcher exits 0 after verify"; else fail "watcher exits 0 after verify (rc=$rc)"; fi
if [[ "$sent" == *"-l|/rename Demo Title Here|"* ]]; then pass "watcher sends /rename with title (-l)"
else fail "watcher sends /rename with title (-l)"; fi
if [[ "$sent" == *"Enter|"* ]]; then pass "watcher sends a separate Enter key"
else fail "watcher sends a separate Enter key"; fi

# A watcher that finds the user typing must not send anything.
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
if [[ -s "$SENT" ]]; then fail "watcher sends nothing while user types"
else pass "watcher sends nothing while user types"; fi

# --- summary -------------------------------------------------------------------
if [[ "$fails" -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$fails test(s) failed."
    exit 1
fi
