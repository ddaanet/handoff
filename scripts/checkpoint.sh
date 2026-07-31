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
field_is_null() { jq -e ".$1 == null" >/dev/null 2>&1 <<<"$payload"; }
field_has_key() { jq -e ".$1 | has(\"$2\")" >/dev/null 2>&1 <<<"$payload"; }

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

# Four skills, two boundaries. The judgment the directive output encodes is
# per-boundary — the same whether or not the agent types the command afterwards
# — so the composition below keys on the boundary and the two skills at each
# one cannot drift in what they tell the agent.
skills='"handoff", "handoff-continue", "precompact" or "compact-continue"'
skill="$(field_get skill)"
case "$skill" in
    handoff | handoff-continue) boundary=clear ;;
    precompact | compact-continue) boundary=compact ;;
    "" | null) err "skill" "required, one of $skills" ;;
    *) err "skill" "must be one of $skills, got \"$skill\"" ;;
esac

commit_mode="$(field_get commit)"
case "$commit_mode" in
    with-commit | without-commit) ;;
    "" | null) err "commit" 'required, one of "with-commit" or "without-commit"' ;;
    *) err "commit" "must be \"with-commit\" or \"without-commit\", got \"$commit_mode\"" ;;
esac

# rename: required under skill:"handoff", forbidden (a schema error, not a
# silent ignore) under all three others. The two driven skills carry their
# title in the sentinel they write, as one of its lines; precompact renames
# nothing at all. Keeping it required in the one place it belongs is what makes
# a `handoff` call that forgot its title an error rather than a silent
# non-rename.
rename=""
if ! field_is_null rename; then
    rename="$(field_get rename)"
fi
if [ "$skill" = "handoff" ]; then
    [ -n "$rename" ] || err "rename" 'required when skill is "handoff"'
else
    [ -z "$rename" ] || err "rename" "forbidden when skill is \"$skill\""
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

if [ -n "$rename" ]; then
    # The sentinel holds the literal keystrokes, so the title becomes the
    # argument of a `/rename` line under a `rename` kind line. It has to be one
    # line: the format is line-oriented and handoff_drive_read would reject a
    # title carrying its own newline. bash-post.sh used to flatten whitespace at
    # consume time; with the sentinel written in its final form there is no
    # consumer left to do it, so it happens here.
    title="$(printf '%s' "$rename" | tr -s '[:space:]' ' ')"
    title="${title# }"; title="${title% }"
    [ -n "$title" ] || err "rename" "must be a non-empty title"
    printf 'rename\n/rename %s\n' "$title" > "$root/$HANDOFF_REL_DRIVE"
fi

# Always written, even with zero lines: bash-post.sh's fast-exit gate is the
# manifest's mere presence, so an empty manifest is what still lets it notice
# and consume a rename-only checkpoint call.
manifest_path="$root/.claude/checkpoint-manifest"
if [ "${#manifest[@]}" -gt 0 ]; then
    printf '%s\n' "${manifest[@]}" > "$manifest_path"
else
    : > "$manifest_path"
fi

# FR9: directive output (memory gate, SDD ledger nudge) unchanged in content
# and composition order from the probes this replaces. Keyed on the boundary,
# not the skill: preparation is identical on both sides of the drive/no-drive
# split, so the pair at each boundary composes the same thing.
memory="$(checkpoint_memory_directive "$root" "$commit_mode")"
case "$boundary" in
    clear)   second="$(checkpoint_todo_suppression "$root")" ;;
    compact) second="$(checkpoint_sdd_directive "$root")" ;;
esac
if [ -n "$memory" ] && [ -n "$second" ]; then
    printf '%s\n\n%s\n' "$memory" "$second"
elif [ -n "$memory" ]; then
    printf '%s\n' "$memory"
elif [ -n "$second" ]; then
    printf '%s\n' "$second"
fi
