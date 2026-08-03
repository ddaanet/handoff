#!/usr/bin/env bats
# Test suite for the detached watcher: the pure predicates and confirmation
# primitives in _watcher-lib.sh, and drive-when-idle.sh end-to-end against a
# tmux stub on PATH (no real tmux/Claude needed).
#
# Run with: bats tests/watcher-test.bats   (from plugin root)

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPTS="$ROOT/scripts"

    # Sample captured pane text.
    busy_text=$'  ⎿  running\n* Flummoxing… (37s · ↓ 2.4k tokens)\n──── name pending ──\n❯ \n────'
    idle_text=$'  ⎿  done\n──── name pending ──\n❯ \n────\n  ▄▂▁15s│3m▅▆ 15:30 / 7d Wed 12:42'
    typing_text=$'──── name pending ──\n❯ hello there\n────'

    # shellcheck source-path=SCRIPTDIR source=../scripts/_watcher-lib.sh disable=SC1091
    . "$SCRIPTS/_watcher-lib.sh"

    STUBDIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUBDIR"
}

# --- _watcher-lib.sh predicates ------------------------------------------------
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

# After a slash command is typed with no Enter, the TUI renders either an
# autocomplete row for the command or `No commands match "…"`. The walker checks
# this before pressing Enter on any line beginning `/` (type-verify-submit).

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

# --- transcript_prompt_count ---------------------------------------------------
# The prose primitive's signal: a genuine user-prompt entry whose text contains
# the marker. is_busy times the spinner and false-fails on a queued submit whose
# turn starts seconds later; the transcript records the accepted prompt at once.
# This helper counts only real submissions — harness-injected user entries
# (isMeta frame, isCompactSummary) and assistant echoes must not count, or a
# prompt that is merely *quoted* in the summary would read as submitted.

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

# --- transcript_title_count ----------------------------------------------------
# FR-F's primitive, and the one that retires the last pane-reading confirmation:
# the old rename watcher grepped the pane for the title's first 20 characters,
# which matches whenever the title is on screen for any other reason. `/rename`
# writes a `custom-title` entry; the harness's own auto-titling writes
# `ai-title`, a distinct type, so an exact match cannot false-positive on it.

TITLE='Driven Transitions Design'

@test "transcript_title_count: counts an exact custom-title match" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    printf '{"type":"custom-title","customTitle":"%s","sessionId":"abc"}\n' "$TITLE" > "$tr"
    run transcript_title_count "$tr" "$TITLE"
    [ "$output" = 1 ]
}

@test "transcript_title_count: an ai-title entry with the same text does not count" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    printf '{"type":"ai-title","customTitle":"%s"}\n' "$TITLE" > "$tr"
    run transcript_title_count "$tr" "$TITLE"
    [ "$output" = 0 ]
}

@test "transcript_title_count: a different title does not count" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    printf '{"type":"custom-title","customTitle":"Something Else"}\n' > "$tr"
    run transcript_title_count "$tr" "$TITLE"
    [ "$output" = 0 ]
}

# Exact, not substring: the prose primitive matches loosely because a prompt is
# quoted all over a transcript, but a title is written whole.
@test "transcript_title_count: a prefix of the title does not count" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    printf '{"type":"custom-title","customTitle":"%s"}\n' "$TITLE" > "$tr"
    run transcript_title_count "$tr" "Driven"
    [ "$output" = 0 ]
}

@test "transcript_title_count: 0 for a missing or unset path" {
    run transcript_title_count "$BATS_TEST_TMPDIR/nope.jsonl" "$TITLE"
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
    run transcript_title_count "" "$TITLE"
    [ "$output" = 0 ]
}

@test "transcript_title_count: skips a malformed line and still counts a later entry" {
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    {
        printf 'not json at all\n'
        printf '{"type":"custom-title","customTitle":"%s"}\n' "$TITLE"
    } > "$tr"
    run transcript_title_count "$tr" "$TITLE"
    [ "$output" = 1 ]
}

# --- the tmux stub -------------------------------------------------------------
# Pane text comes from $STUBDIR/pane_idle.txt until a literal send has happened,
# and from $STUBDIR/pane_after_l.txt thereafter — the shape of the real TUI,
# which renders command recognition only once the text is in the composer. Every
# send-keys call is logged to $SENT; each Enter additionally runs
# $STUBDIR/on_enter.sh if the test installed one.
make_stub() {
    SENT="$STUBDIR/sent.log"; : > "$SENT"
    printf '%s\n' '──── x ──' '❯ ' > "$STUBDIR/pane_idle.txt"
    cp "$STUBDIR/pane_idle.txt" "$STUBDIR/pane_after_l.txt"
    rm -f "$STUBDIR/on_enter.sh" "$STUBDIR/sent_l"
    cat > "$STUBDIR/tmux" <<STUB
#!/usr/bin/env bash
sub="\$1"; shift
case "\$sub" in
  capture-pane)
    if [ -f "$STUBDIR/sent_l" ]; then cat "$STUBDIR/pane_after_l.txt"
    else cat "$STUBDIR/pane_idle.txt"; fi ;;
  send-keys)
    printf '%s|' "\$@" >> "$SENT"; printf '\n' >> "$SENT"
    case "\$*" in
      *Enter*) [ -x "$STUBDIR/on_enter.sh" ] && "$STUBDIR/on_enter.sh" ;;
      *" -l "*) touch "$STUBDIR/sent_l" ;;
    esac ;;
esac
exit 0
STUB
    chmod +x "$STUBDIR/tmux"
}

# Install an on-Enter side effect (the harness reacting to a submitted line).
on_enter() {
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "$STUBDIR/on_enter.sh"
    chmod +x "$STUBDIR/on_enter.sh"
}

# Run the walker with the stub on PATH and short tunables. Extra env goes in
# $WALK_ENV; the lines to type are the arguments.
walk() {
    run env PATH="$STUBDIR:$PATH" \
        HANDOFF_WATCHER_TIMEOUT="${WALK_TIMEOUT:-5}" HANDOFF_WATCHER_POLL=0.01 \
        HANDOFF_WATCHER_VERIFY_DELAY=0.01 HANDOFF_WATCHER_CONSUME_POLL=0.05 \
        HANDOFF_WATCHER_CONSUME_TIMEOUT="${WALK_CONSUME:-1}" \
        ${WALK_ENV[@]+"${WALK_ENV[@]}"} \
        bash "$SCRIPTS/drive-when-idle.sh" '%9' "$@"
}

# --- the confirmation primitives are predicates --------------------------------
# They used to `exit` from inside a helper, which is only safe as a watcher's
# final statement — the sole reason the design needed a terminal and a
# non-terminal form of each. One walker deciding failure for the whole sequence
# removes the distinction. If any of them exits, REACHED-END never prints.

@test "confirmation primitives return rather than exit, and record nothing" {
    make_stub
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    : > "$BATS_TEST_TMPDIR/pending"
    cat > "$BATS_TEST_TMPDIR/probe.sh" <<PROBE
PANE=%9
. "$SCRIPTS/_watcher-lib.sh"
VERIFY_DELAY=0.01; CONSUME_TIMEOUT=1; CONSUME_POLL=0.05
HANDOFF_TRANSCRIPT="$BATS_TEST_TMPDIR/absent.jsonl"
HANDOFF_PENDING_FILE="$BATS_TEST_TMPDIR/pending"
submit_consumed; echo "consumed=\$?"
submit_titled "Nope"; echo "titled=\$?"
submit_prompted "nope"; echo "prompted=\$?"
echo REACHED-END
PROBE
    run env PATH="$STUBDIR:$PATH" HANDOFF_FAIL_FILE="$fail_file" \
        bash "$BATS_TEST_TMPDIR/probe.sh"
    [[ "$output" == *"consumed=1"* ]]
    [[ "$output" == *"titled=1"* ]]
    [[ "$output" == *"prompted=1"* ]]
    [[ "$output" == *"REACHED-END"* ]]
    # Failure is the walker's to declare, once, at the top.
    [ ! -e "$fail_file" ]
}

# --- the walker: one line ------------------------------------------------------

@test "a slash line is typed literally, recognition read back, then Entered" {
    make_stub
    printf '%s\n' '/compact  Compact the conversation' '❯ /compact' > "$STUBDIR/pane_after_l.txt"
    WALK_ENV=(HANDOFF_PENDING_FILE="$BATS_TEST_TMPDIR/absent")
    walk '/compact keep the parser work'
    [ "$status" -eq 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"-l|/compact keep the parser work|"* ]]
    [[ "$sent" == *"Enter|"* ]]
    # The literal send must precede Enter — recognition is checked in between.
    l_line=$(grep -n -- '-l|' "$SENT" | head -1 | cut -d: -f1)
    e_line=$(grep -n 'Enter|' "$SENT" | head -1 | cut -d: -f1)
    [ "$l_line" -lt "$e_line" ]
}

@test "an unrecognized command is cleared with C-u and never Entered" {
    make_stub
    printf '%s\n' 'No commands match "/compzzz"' '❯ /compzzz' > "$STUBDIR/pane_after_l.txt"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_FAIL_FILE="$fail_file")
    walk '/compzzz' 'a continuation that must never be typed'
    [ "$status" -ne 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"C-u|"* ]]
    [[ "$sent" != *"Enter|"* ]]
    [[ "$sent" != *"continuation"* ]]
    grep -qi 'recognize' "$fail_file"
    [ "$(wc -l < "$fail_file")" -eq 1 ]
}

@test "nothing is sent while the user is composing" {
    make_stub
    printf '%s\n' '──── x ──' '❯ half-typed thought' > "$STUBDIR/pane_idle.txt"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_FAIL_FILE="$fail_file")
    WALK_TIMEOUT=1
    walk '/clear' 'should not send'
    [ "$status" -ne 0 ]
    [ ! -s "$SENT" ]
    grep -qi 'composing' "$fail_file"
}

# Recording a failure is additive, never a precondition for driving the pane.
@test "a non-delivery with no HANDOFF_FAIL_FILE still stops the walker" {
    make_stub
    WALK_ENV=(HANDOFF_TRANSCRIPT="$BATS_TEST_TMPDIR/absent.jsonl")
    walk 'a prose line nothing will accept'
    [ "$status" -ne 0 ]
}

# --- the walker: confirmation dispatches on the command, not the kind ----------

@test "a /rename line confirms by a custom-title entry" {
    make_stub
    tr="$BATS_TEST_TMPDIR/t.jsonl"; : > "$tr"
    on_enter "printf '{\"type\":\"custom-title\",\"customTitle\":\"$TITLE\"}\n' >> '$tr'"
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr")
    walk "/rename $TITLE"
    [ "$status" -eq 0 ]
    [[ "$(cat "$SENT")" == *"-l|/rename $TITLE|"* ]]
}

# The old watcher grepped the pane for the title. A title on screen for another
# reason — here, the composer's own echo of the line just typed — must not count
# as a rename that landed.
@test "a /rename line is not confirmed by the title merely appearing on the pane" {
    make_stub
    printf '%s\n' "──── $TITLE ──" '❯ ' > "$STUBDIR/pane_after_l.txt"
    tr="$BATS_TEST_TMPDIR/t.jsonl"; : > "$tr"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr" HANDOFF_FAIL_FILE="$fail_file")
    walk "/rename $TITLE"
    [ "$status" -ne 0 ]
    grep -qi 'title never changed' "$fail_file"
}

# A stale entry from before the line was typed must not read as a submit: the
# baseline is taken before the first Enter.
@test "a /rename line is not confirmed by a pre-existing custom-title entry" {
    make_stub
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    printf '{"type":"custom-title","customTitle":"%s"}\n' "$TITLE" > "$tr"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr" HANDOFF_FAIL_FILE="$fail_file")
    walk "/rename $TITLE"
    [ "$status" -ne 0 ]
    grep -qi 'title never changed' "$fail_file"
}

# Submitting /compact or /clear starts a transition, but the TUI shows no chrome
# is_busy matches within the confirm window — observed live 2026-07-22, where a
# compaction ran for 103s and the watcher still reported "three Enters did not
# submit it". The authoritative signal is the one the transition's own
# SessionStart acts on: it consumes .claude/autodrive.
@test "a /compact line confirms by the pending file being consumed" {
    make_stub
    printf '%s\n' '/compact  Compact the conversation' '❯ /compact' > "$STUBDIR/pane_after_l.txt"
    pending="$BATS_TEST_TMPDIR/autodrive"; : > "$pending"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    # Stand in for SessionStart(compact), which consumes the file when the
    # compaction completes — well after any pane-chrome window would close.
    ( sleep 0.3; rm -f "$pending" ) &
    WALK_ENV=(HANDOFF_PENDING_FILE="$pending" HANDOFF_FAIL_FILE="$fail_file")
    WALK_CONSUME=5
    walk '/compact keep the parser work'
    [ "$status" -eq 0 ]
    [ ! -e "$fail_file" ]
}

@test "a /compact line is reported when no transition ever consumes it" {
    make_stub
    printf '%s\n' '/compact  Compact the conversation' '❯ /compact' > "$STUBDIR/pane_after_l.txt"
    pending="$BATS_TEST_TMPDIR/autodrive"; : > "$pending"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_PENDING_FILE="$pending" HANDOFF_FAIL_FILE="$fail_file")
    walk '/compact keep the parser work'
    [ "$status" -ne 0 ]
    grep -qi 'no /compact followed' "$fail_file"
}

# An unconfirmable submit is not a failed one.
@test "a /clear line with nothing to confirm against is not reported as failed" {
    make_stub
    printf '%s\n' '/clear  Clear the conversation' '❯ /clear' > "$STUBDIR/pane_after_l.txt"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_FAIL_FILE="$fail_file")
    walk '/clear'
    [ "$status" -eq 0 ]
    [ ! -e "$fail_file" ]
}

# Regression (session 8e39f620): the accepted continuation was queued behind
# post-compaction settling, so no spinner showed in the confirm window and the
# is_busy check reported non-delivery for a line that arrived. The pane here
# never goes busy, yet the transcript gains the entry — confirmation must pass.
@test "prose confirms a queued submit that shows no spinner" {
    make_stub
    tr="$BATS_TEST_TMPDIR/t.jsonl"
    # Seeded with a stale pre-transition copy of the same prompt: a passing
    # confirmation must detect a NEW entry, not the marker's mere presence.
    printf '{"type":"user","message":{"role":"user","content":"continue with task 3 (stale copy)"}}\n' > "$tr"
    on_enter "printf '{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"continue with task 3\"}}\n' >> '$tr'"
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr")
    walk 'continue with task 3'
    [ "$status" -eq 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" == *"-l|continue with task 3|"* ]]
    # Exactly one Enter: the transcript gained the entry on the first submit.
    [ "$(grep -c 'Enter|' "$SENT")" -eq 1 ]
}

@test "prose retries three times and reports when the Enter is absorbed" {
    make_stub
    tr="$BATS_TEST_TMPDIR/t.jsonl"; : > "$tr"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr" HANDOFF_FAIL_FILE="$fail_file")
    walk 'continue with task 3'
    [ "$status" -ne 0 ]

    sent="$(cat "$SENT")"
    [ "$(grep -c 'Enter|' "$SENT")" -eq 3 ]
    # The text is never re-sent — that would concatenate a second copy.
    [ "$(grep -c -- '-l|' "$SENT")" -eq 1 ]
    grep -qi 'continuation prompt' "$fail_file"
    [ "$(wc -l < "$fail_file")" -eq 1 ]
}

# Regression (session 5c5b043b, 2026-07-24): a live compaction left an ~18s gap
# between the summary being ready and compact_boundary actually landing in the
# transcript — the Enter registered but confirmation showed up long after the
# three fast retries (~1.5s in production) gave up. Here the Enter is absorbed by
# the stub, but the transcript entry lands asynchronously well after the
# fast-retry phase — confirmation must still succeed, and without resending Enter.
@test "prose confirms a submit that lands after the fast-retry window" {
    make_stub
    tr="$BATS_TEST_TMPDIR/t.jsonl"; : > "$tr"
    ( sleep 1
      printf '{"type":"user","message":{"role":"user","content":"continue with task 3"}}\n' >> "$tr" ) &
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr")
    WALK_CONSUME=5
    walk 'continue with task 3'
    [ "$status" -eq 0 ]
    [ "$(grep -c 'Enter|' "$SENT")" -eq 3 ]
}

# --- the walker: sequencing ----------------------------------------------------

@test "a multi-line sequence types every line, in order" {
    make_stub
    tr="$BATS_TEST_TMPDIR/t.jsonl"; : > "$tr"
    pending="$BATS_TEST_TMPDIR/autodrive"; : > "$pending"
    on_enter "printf '{\"type\":\"custom-title\",\"customTitle\":\"$TITLE\"}\n' >> '$tr'; rm -f '$pending'"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr" HANDOFF_PENDING_FILE="$pending" HANDOFF_FAIL_FILE="$fail_file")
    walk "/rename $TITLE" '/clear'
    [ "$status" -eq 0 ]
    [ ! -e "$fail_file" ]

    rename_line=$(grep -n -- "-l|/rename" "$SENT" | head -1 | cut -d: -f1)
    clear_line=$(grep -n -- "-l|/clear" "$SENT" | head -1 | cut -d: -f1)
    [ -n "$rename_line" ] && [ -n "$clear_line" ]
    [ "$rename_line" -lt "$clear_line" ]
}

# The point of confirming per line: a rename that never lands under kind `clear`
# must cost a wrong title and nothing more. If the sequence carried on, /clear
# would fire and the session would be gone.
@test "a line that never confirms stops the sequence" {
    make_stub
    tr="$BATS_TEST_TMPDIR/t.jsonl"; : > "$tr"
    fail_file="$BATS_TEST_TMPDIR/autodrive.failed"
    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr" HANDOFF_FAIL_FILE="$fail_file")
    walk "/rename $TITLE" '/clear' 'pick up per the task file'
    [ "$status" -ne 0 ]

    sent="$(cat "$SENT")"
    [[ "$sent" != *"/clear"* ]]
    [[ "$sent" != *"pick up per the task file"* ]]
    # Exactly one reason recorded, for the line that actually failed.
    [ "$(wc -l < "$fail_file")" -eq 1 ]
    grep -q "$TITLE" "$fail_file"
}

# FR-H. Confirming a line can take minutes and the pane is live throughout, so
# idleness established before it says nothing about now. wait_for_idle falls
# through when it times out — is_typing is the hard gate, and a pane that is busy
# without a composed prompt is typed into eventually — so the observable is that
# the second line's send is DELAYED by a full TIMEOUT. Without the re-gate the
# gap collapses to nothing. Mutation-checked: a missing re-gate passes every
# other test in this file.
@test "a sequence re-gates on idle between lines" {
    make_stub
    printf '%s\n' '* Flummoxing… (12s · ↓ 1k tokens)' '❯ ' > "$STUBDIR/pane_after_l.txt"
    tr="$BATS_TEST_TMPDIR/t.jsonl"; : > "$tr"
    on_enter "printf '{\"type\":\"custom-title\",\"customTitle\":\"$TITLE\"}\n' >> '$tr'"

    WALK_ENV=(HANDOFF_TRANSCRIPT="$tr")
    WALK_TIMEOUT=3
    start=$SECONDS
    walk "/rename $TITLE" 'the second line'
    elapsed=$((SECONDS - start))

    # Both lines were sent...
    [[ "$(cat "$SENT")" == *"-l|the second line|"* ]]
    # ...but the second waited out the busy pane rather than following at once.
    [ "$elapsed" -ge 2 ]
}
