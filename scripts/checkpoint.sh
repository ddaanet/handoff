#!/usr/bin/env bash
# handoff-checkpoint: the one write path for the handoff/precompact wrap-up.
# Replaces the activation wipe, the agent's three separate Write calls, the
# activation predicate, and the two read-only probes with a single call: the
# skill assembles the whole wrap-up as JSON and pipes it to this script on
# stdin via a heredoc. See docs/changelog/2026-07-27-one-channel-one-writer.md and
# plans/2026-07-27-checkpoint-channel-design.md for the schema and rationale.
#
# FR2: a schema violation exits 2 and names the offending field on stderr.
# NFR1: nothing here mutates git state and no tmux runs at all — this is the
# agent's sandboxed Bash, where a `git add` can strand .git/index.lock and tmux
# is unreachable. The directive path queries git read-only (see
# _checkpoint-lib.sh); beyond that the checkpoint writes files (task/todo
# content, the manifest, the armed transition) and nothing else;
# scripts/bash-post.sh (PostToolUse(Bash)) does the staging in hook context,
# driven by the manifest this script leaves, and the sentinel is armed at Stop
# by stop-drive.sh like any other.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# shellcheck source-path=SCRIPTDIR source=_checkpoint-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_checkpoint-lib.sh"

err() {
    printf 'handoff-checkpoint: %s: %s\n' "$1" "$2" >&2
    exit 2
}

payload="$(cat)"
jq -e . >/dev/null 2>&1 <<<"$payload" || err "payload" "malformed JSON on stdin"

field_get() { jq -r ".$1" <<<"$payload"; }
field_type() { jq -r ".$1 | type" <<<"$payload"; }
field_is_null() { jq -e ".$1 == null" >/dev/null 2>&1 <<<"$payload"; }
field_has_key() { jq -e ".$1 | has(\"$2\")" >/dev/null 2>&1 <<<"$payload"; }
payload_has_key() { jq -e "has(\"$1\")" >/dev/null 2>&1 <<<"$payload"; }

# One line, with something on it: the shape of every string that becomes a line
# of the sentinel. The format is line-oriented, so an embedded newline would
# make the file unreadable — and in the TUI one Enter is one submit, so it would
# also submit the line early.
require_one_line() {
    local field="$1" value="$2"
    [ -n "$(printf '%s' "$value" | tr -d '[:space:]')" ] \
        || err "$field" "must not be empty or whitespace only"
    case "$value" in
        *$'\n'*) err "$field" "must be a single line" ;;
    esac
}

# The root cannot be resolved here: this is the agent's Bash, where
# CLAUDE_PROJECT_DIR is unset and $PWD is wherever the session cwd has drifted
# to — and a fallback to $PWD is silently wrong in exactly the drift case, the
# writer landing in one repo while every reader stays in the other. SessionStart
# published the root instead; read it back. A live session always has a pointer,
# so its absence is abnormal and refusing is the point.
session_id="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$session_id" ] \
    || err "root" "CLAUDE_CODE_SESSION_ID is unset, so this session's root pointer cannot be addressed"
pointer="$(handoff_pointer_path "$session_id")"
[ -f "$pointer" ] \
    || err "root" "no session root pointer at $pointer; restart the session to publish one"
root="$(head -n1 "$pointer")"
[ -d "$root" ] || err "root" "the session root pointer at $pointer does not name a directory (got \"$root\")"

# Two boundaries, one skill each — plus autoname, which is neither. Whether the
# transition is typed is a field of the payload, not a skill of its own: the
# judgment the directive output encodes was always per-boundary, and the driven
# skills only ever added the keystrokes.
skill="$(field_get skill)"
case "$skill" in
    handoff | precompact | autoname) ;;
    "" | null) err "skill" 'required, one of "handoff", "precompact" or "autoname"' ;;
    *) err "skill" "must be \"handoff\", \"precompact\" or \"autoname\", got \"$skill\"" ;;
esac

# autoname carries one field beside its own name. It writes neither file, makes
# no commit-awareness decision, no transition decision and no continuation
# decision — so a field for one would be a decision nobody acted on, which is a
# schema error here for the same reason `rename` is under "precompact".
if [ "$skill" = "autoname" ]; then
    for forbidden in commit task todo clear compact continue; do
        ! payload_has_key "$forbidden" \
            || err "$forbidden" 'forbidden when skill is "autoname"'
    done
else
    commit_mode="$(field_get commit)"
    case "$commit_mode" in
        with-commit | without-commit) ;;
        "" | null) err "commit" 'required, one of "with-commit" or "without-commit"' ;;
        *) err "commit" "must be \"with-commit\" or \"without-commit\", got \"$commit_mode\"" ;;
    esac
fi

# rename: required wherever a title is decided — "handoff" and "autoname" —
# forbidden (a schema error, not a silent ignore) under "precompact", which
# renames nothing at all. Keeping it required in the places it belongs is what
# makes a call that forgot its title an error rather than a silent non-rename.
rename=""
if ! field_is_null rename; then
    rename="$(field_get rename)"
fi
if [ "$skill" = "precompact" ]; then
    [ -z "$rename" ] || err "rename" "forbidden when skill is \"$skill\""
else
    [ -n "$rename" ] || err "rename" "required when skill is \"$skill\""
    title="$(printf '%s' "$rename" | tr -s '[:space:]' ' ')"
    title="${title# }"; title="${title% }"
    [ -n "$title" ] || err "rename" "must be a non-empty title"
fi

# The transition, and the continuation prompt submitted into what it opens.
# Both required, with no default: a default is the answer given by an agent that
# never considered the question, and considering it is the whole contribution.
#
# The transition field is named after the command it types, and its value is
# that command's argument — /clear takes none, so it is a bool; /compact takes
# an optional focus directive, so it is a bool or the directive itself. The
# other boundary's field is a schema error rather than a silent ignore, for the
# same reason `rename` is.
#
# `false` does not mean "no sentinel". It means the command is not typed: the
# file still records which transition is expected, which is what both loaders
# gate the frame's re-injection on.
drive_kind=""
drive_cmds=()
typed=false
if [ "$skill" = "autoname" ]; then
    drive_kind=rename
    drive_cmds=("/rename $title")
elif [ "$skill" = "handoff" ]; then
    ! payload_has_key compact || err "compact" 'forbidden when skill is "handoff"'
    payload_has_key clear || err "clear" 'required when skill is "handoff"'
    [ "$(field_type clear)" = "boolean" ] || err "clear" "must be true or false"
    if [ "$(field_get clear)" = "true" ]; then
        typed=true
        drive_kind=clear
        drive_cmds=("/rename $title" "/clear")
    else
        # No transition, but the session is still renamed — the same kind an
        # autoname call composes above.
        drive_kind=rename
        drive_cmds=("/rename $title")
    fi
else
    ! payload_has_key clear || err "clear" 'forbidden when skill is "precompact"'
    payload_has_key compact || err "compact" 'required when skill is "precompact"'
    drive_kind=compact
    case "$(field_type compact)" in
        boolean)
            if [ "$(field_get compact)" = "true" ]; then
                typed=true
                drive_cmds=("/compact")
            fi
            ;;
        string)
            directive="$(field_get compact)"
            require_one_line "compact" "$directive"
            typed=true
            drive_cmds=("/compact $directive")
            ;;
        *) err "compact" "must be true, false, or a focus directive string" ;;
    esac
fi

continuation=""
if [ "$skill" != "autoname" ]; then
    payload_has_key continue || err "continue" "required, either null or one line of prose"
    if ! field_is_null continue; then
        [ "$(field_type continue)" = "string" ] \
            || err "continue" "must be null or one line of prose"
        continuation="$(field_get continue)"
        require_one_line "continue" "$continuation"
        # The walker dispatches on the leading character: a prose line that
        # looked like a command would be confirmed by the wrong primitive.
        case "$continuation" in
            /*) err "continue" "must not begin with \`/\`" ;;
        esac
        # Nothing would type it. A silent drop loses a prompt the agent authored
        # and reports nothing about it.
        $typed || err "continue" "must be null when the transition is not typed"
    fi
fi

# Validate one Write-form-or-null field ($1 = "task", never Edit) or one
# Write/Edit-form-or-null field ($1 = "todo"). Sets ${1}_action to
# none|write|edit and, on write/edit, ${1}_content or ${1}_old_string +
# ${1}_new_string via nameref-free direct assignment (two call sites only, so
# duplicating the field name beats an eval-based generic helper).
validate_task() {
    task_action=none
    task_content=""
    field_is_null task && return 0

    jq -e '.task | type == "object"' >/dev/null 2>&1 <<<"$payload" \
        || err "task" "must be an object or null"
    if field_has_key task old_string || field_has_key task new_string; then
        err "task" "old_string/new_string are not allowed for task (Write form only)"
    fi
    # {"content": null} is equivalent to task: null — no-op, and file_path
    # is not required for a no-op.
    if field_has_key task content && field_is_null task.content; then
        return 0
    fi
    field_has_key task file_path || err "task.file_path" "required"
    field_has_key task content || err "task.content" "required"

    local file_path resolved expected
    file_path="$(field_get task.file_path)"
    if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
        err "task.file_path" "must be a non-empty string"
    fi
    { read -r resolved; read -r expected; } \
        < <(handoff_resolve "$file_path" "$root/$HANDOFF_REL_TASK")
    [ "$resolved" = "$expected" ] \
        || err "task.file_path" "must resolve to \$root/$HANDOFF_REL_TASK (got $file_path)"

    task_content="$(field_get task.content)"
    task_action="write"
}

validate_todo() {
    todo_action=none
    todo_content=""
    todo_old_string=""
    todo_new_string=""
    field_is_null todo && return 0

    jq -e '.todo | type == "object"' >/dev/null 2>&1 <<<"$payload" \
        || err "todo" "must be an object or null"
    # {"content": null} (with no old_string/new_string) is equivalent to
    # todo: null — no-op, and file_path is not required for a no-op.
    if field_has_key todo content && field_is_null todo.content \
        && ! field_has_key todo old_string && ! field_has_key todo new_string; then
        return 0
    fi
    field_has_key todo file_path || err "todo.file_path" "required"

    local file_path resolved expected has_content has_old has_new
    file_path="$(field_get todo.file_path)"
    if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
        err "todo.file_path" "must be a non-empty string"
    fi
    { read -r resolved; read -r expected; } \
        < <(handoff_resolve "$file_path" "$root/$HANDOFF_REL_TODO")
    [ "$resolved" = "$expected" ] \
        || err "todo.file_path" "must resolve to \$root/$HANDOFF_REL_TODO (got $file_path)"

    has_content=false; has_old=false; has_new=false
    field_has_key todo content && has_content=true
    field_has_key todo old_string && has_old=true
    field_has_key todo new_string && has_new=true

    if $has_content && { $has_old || $has_new; }; then
        err "todo" "content and old_string/new_string are mutually exclusive"
    fi

    if $has_content; then
        todo_content="$(field_get todo.content)"
        todo_action="write"
    elif $has_old || $has_new; then
        if ! { $has_old && $has_new; }; then
            err "todo" "old_string and new_string must both be present"
        fi
        todo_old_string="$(field_get todo.old_string)"
        todo_new_string="$(field_get todo.new_string)"
        todo_action="edit"
    else
        err "todo" "must have content, or old_string and new_string"
    fi
}

validate_task
validate_todo

# Exact string replacement, first occurrence, erroring (naming the field) if
# old_string is absent or ambiguous. Applied by the checkpoint, not the
# harness — python3 (already a dependency, see handoff_resolve) does the
# replacement so multi-line old/new strings need no shell quoting.
apply_edit() {
    local field="$1" path="$2" old="$3" new="$4"
    FIELD="$field" TARGET_PATH="$path" OLD_STRING="$old" NEW_STRING="$new" \
        python3 - <<'PY'
import os, sys

field = os.environ["FIELD"]
path = os.environ["TARGET_PATH"]
old = os.environ["OLD_STRING"]
new = os.environ["NEW_STRING"]

with open(path, encoding="utf-8") as fh:
    content = fh.read()

count = content.count(old)
if count == 0:
    print(f"handoff-checkpoint: {field}.old_string: not found in {path}", file=sys.stderr)
    sys.exit(2)
if count > 1:
    print(f"handoff-checkpoint: {field}.old_string: ambiguous, {count} occurrences in {path}", file=sys.stderr)
    sys.exit(2)

content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(content)
PY
}

manifest=()

task_path="$root/$HANDOFF_REL_TASK"
if [ "$task_action" = "write" ]; then
    printf '%s' "$task_content" > "$task_path"
    if checkpoint_is_empty_body "$task_content"; then
        rm -f "$task_path"
        manifest+=("D $HANDOFF_REL_TASK")
    else
        manifest+=("W $HANDOFF_REL_TASK")
    fi
fi

todo_path="$root/$HANDOFF_REL_TODO"
case "$todo_action" in
    write)
        printf '%s' "$todo_content" > "$todo_path"
        ;;
    edit)
        [ -f "$todo_path" ] \
            || err "todo.old_string" "edit requested but $HANDOFF_REL_TODO does not exist"
        apply_edit "todo" "$todo_path" "$todo_old_string" "$todo_new_string" || exit 2
        ;;
esac
if [ "$todo_action" != "none" ]; then
    if checkpoint_is_empty_body "$(cat "$todo_path")"; then
        rm -f "$todo_path"
        manifest+=("D $HANDOFF_REL_TODO")
    else
        manifest+=("W $HANDOFF_REL_TODO")
    fi
fi

# Always written, even with zero lines: bash-post.sh's fast-exit gate is the
# manifest's mere presence, so an empty manifest is what still lets it notice
# and consume a checkpoint call that touched neither file.
manifest_path="$root/.claude/checkpoint-manifest"
if [ "${#manifest[@]}" -gt 0 ]; then
    printf '%s\n' "${manifest[@]}" > "$manifest_path"
else
    : > "$manifest_path"
fi

# FR9: directive output (memory gate, SDD ledger nudge) unchanged in content
# and composition order from the probes this replaces. One per boundary, and
# the skill names the boundary.
#
# The memory gate is inside the branch, not ahead of it: autoname is not a
# boundary, its own description promises no memory write, and a memory directive
# is an instruction to make one.
memory=""
second=""
case "$skill" in
    handoff)
        memory="$(checkpoint_memory_directive "$root" "$commit_mode")"
        second="$(checkpoint_todo_boundary "$root")"
        ;;
    precompact)
        memory="$(checkpoint_memory_directive "$root" "$commit_mode")"
        second="$(checkpoint_sdd_directive "$root")"
        ;;
esac

# The sentinel: its state, its kind, then the literal keystrokes. Composed here
# rather than by the skill body, so the payload's transition fields are what
# decides the file rather than advice the agent is asked to follow — and so the
# line shapes live in one place instead of being restated as prose in two.
#
# The hazard `held` exists for: keystrokes reaching a pane whose turn is about
# to end on an approval question. A transition armed alongside that question
# clears or compacts away the very conversation the answer applies to. So a
# sentinel that types waits while a memory gate is outstanding, and
# handoff-approved is what releases it; one that types nothing has no such
# hazard. Only the memory gate defers — the ledger nudge and the todo boundary
# are acts, not questions.
state=armed
if $typed && [ -n "$memory" ]; then
    state=held
    memory="$memory"$'\n\n'"$(checkpoint_arming_directive)"
fi

drive_path="$root/$HANDOFF_REL_DRIVE"
printf '%s\n' "$state" "$drive_kind" \
    ${drive_cmds[@]+"${drive_cmds[@]}"} \
    ${continuation:+"$continuation"} \
    > "$drive_path"

# Read back what was just composed. The composer and the parser are the two
# halves of one format, and this is the only thing that would notice them
# drifting apart — every other reader of this file runs in a later turn, in a
# hook, where a rejection is a silent no-op.
if ! handoff_drive_read "$drive_path"; then
    rm -f "$drive_path"
    err "transition" "composed a sentinel this version cannot read back — $DRIVE_ERR"
fi

if [ -n "$memory" ] && [ -n "$second" ]; then
    printf '%s\n\n%s\n' "$memory" "$second"
elif [ -n "$memory" ]; then
    printf '%s\n' "$memory"
elif [ -n "$second" ]; then
    printf '%s\n' "$second"
fi
