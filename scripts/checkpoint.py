#!/usr/bin/env python3
"""Handoff-checkpoint: the one write path for the handoff/precompact wrap-up.

Reads a JSON payload on stdin, validates it against the schema (FR2 — a
violation exits 2 naming the offending field on stderr), applies the task/todo
tagged union — content, or an object naming an action (FR5/FR6) — writes the
manifest (FR7), composes the sentinel (FR8), and prints the directive output
(FR9).

NFR1: nothing here mutates git state and no tmux runs — this is the agent's
sandboxed Bash. scripts/bash-post.sh (PostToolUse(Bash), bash, unmoved) does the
staging, driven by the manifest this script leaves; the sentinel is armed at
Stop by stop-drive.sh (bash, unmoved) like any other.

Port of checkpoint.sh — see docs/changelog/2026-08-10-python-split.md. The
composer reads its own sentinel back through handoff_drive_read, which stays the
single bash implementation of the sentinel grammar (still used by stop-drive.sh,
load-compact.sh, load-handoff.sh and report-watcher-failure.sh) — so this shells
out to it rather than reimplementing the grammar a second time, which is exactly
the drift the single-parser design exists to prevent.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any, Literal, NamedTuple, NoReturn, cast

import _checkpoint_lib as lib

# A parsed JSON object. The payload's shape is validated at runtime (FR2),
# not by static typing — every value is Any until a validate_* function
# narrows it.
JSONDict = dict[str, Any]

# Mirrors _lib.sh's HANDOFF_REL_* constants. Changing either side is a
# breaking change (see CLAUDE.md conventions); kept in sync by hand rather
# than sourced, since _lib.sh stays bash and these three are frozen in
# practice.
HANDOFF_REL_TASK = ".claude/handoff-task.md"
HANDOFF_REL_TODO = ".claude/handoff-todo.md"
HANDOFF_REL_DRIVE = ".claude/autodrive"

_LIB_SH = Path(__file__).resolve().parent / "_lib.sh"


class Transition(NamedTuple):
    """The sentinel's kind, its command lines, and whether it is typed."""

    kind: str
    cmds: list[str]
    typed: bool


def err(field: str, message: str) -> NoReturn:
    """Print a schema/write-time error naming field, then exit 2."""
    print(f"handoff-checkpoint: {field}: {message}", file=sys.stderr)
    raise SystemExit(2)


def _json_type(value: object) -> str:
    """Return the jq-style type name of a decoded JSON value."""
    if isinstance(value, bool):
        return "boolean"
    checks: list[tuple[type | tuple[type, ...], str]] = [
        (type(None), "null"),
        ((int, float), "number"),
        (str, "string"),
        (list, "array"),
        (dict, "object"),
    ]
    for types, name in checks:
        if isinstance(value, types):
            return name
    return "unknown"


def require_one_line(field: str, value: str) -> None:
    """Error unless value is non-blank and holds no embedded newline."""
    if not re.sub(r"\s", "", value):
        err(field, "must not be empty or whitespace only")
    if "\n" in value:
        err(field, "must be a single line")


def read_payload() -> JSONDict:
    """Parse the JSON payload on stdin, or error naming "payload"."""
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        err("payload", "malformed JSON on stdin")
    if not isinstance(payload, dict):
        err("payload", "malformed JSON on stdin")
    return payload


def validate_root() -> Path:
    """Return HANDOFF_ROOT from the environment.

    Injected by inject-checkpoint-root.sh into the very command that invokes
    this.
    """
    root = os.environ.get("HANDOFF_ROOT", "")
    if not root:
        err(
            "root",
            "HANDOFF_ROOT is unset — call via the handoff-checkpoint shim on PATH, "
            "unmodified, so the PreToolUse(Bash) hook recognises and injects it",
        )
    path = Path(root)
    if not path.is_dir():
        err("root", f'HANDOFF_ROOT does not name a directory (got "{root}")')
    return path


def validate_skill(payload: JSONDict) -> str:
    """Return the skill name.

    One of "handoff", "precompact", "autoname" or "restart".
    """
    skill = payload.get("skill")
    if "skill" not in payload or skill in (None, ""):
        err(
            "skill",
            'required, one of "handoff", "precompact", "autoname" or "restart"',
        )
    if skill not in ("handoff", "precompact", "autoname", "restart"):
        err(
            "skill",
            f'must be "handoff", "precompact", "autoname" or "restart", got "{skill}"',
        )
    return cast("str", skill)


def validate_commit_mode(payload: JSONDict, skill: str) -> str:
    """Return the commit mode.

    "" for autoname/restart (neither carries commit awareness); the commit mode
    string otherwise.
    """
    if skill in ("autoname", "restart"):
        return ""
    commit_mode = payload.get("commit")
    if commit_mode not in ("with-commit", "without-commit"):
        if commit_mode in (None, ""):
            err("commit", 'required, one of "with-commit" or "without-commit"')
        err("commit", f'must be "with-commit" or "without-commit", got "{commit_mode}"')
    return cast("str", commit_mode)


def validate_autoname_forbidden_fields(payload: JSONDict) -> None:
    """Error naming the field if any boundary-only field is present."""
    for forbidden in ("commit", "task", "todo", "clear", "compact", "continue"):
        if forbidden in payload:
            err(forbidden, 'forbidden when skill is "autoname"')


def validate_restart_forbidden_fields(payload: JSONDict) -> None:
    """Error naming the field if any boundary-only field is present.

    Unlike autoname, restart's own payload DOES carry `continue` — its own third
    typed line — so that field is not in this set.
    """
    for forbidden in ("commit", "task", "todo", "rename", "clear", "compact"):
        if forbidden in payload:
            err(forbidden, 'forbidden when skill is "restart"')


def validate_rename(payload: JSONDict, skill: str) -> str:
    """Return the flattened title.

    Required wherever a title is decided (handoff, autoname) and forbidden under
    precompact/restart by key presence.
    """
    if skill in ("precompact", "restart"):
        if "rename" in payload:
            err("rename", f'forbidden when skill is "{skill}"')
        return ""
    if "rename" not in payload or payload.get("rename") is None:
        err("rename", f'required when skill is "{skill}"')
    if _json_type(payload["rename"]) != "string":
        err("rename", f"must be a title string, got {_json_type(payload['rename'])}")
    title = re.sub(r"\s+", " ", payload["rename"]).strip()
    if not title:
        err("rename", "must be a non-empty title")
    return title


def build_transition(payload: JSONDict, skill: str, title: str) -> Transition:
    """Return the transition this call types, per the skill's own rules."""
    if skill == "autoname":
        return Transition("rename", [f"/rename {title}"], typed=False)
    if skill == "restart":
        return _build_restart_transition()
    if skill == "handoff":
        return _build_handoff_transition(payload, title)
    return _build_precompact_transition(payload)


def _build_restart_transition() -> Transition:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not session_id:
        err(
            "restart",
            "CLAUDE_CODE_SESSION_ID is unset — cannot compose the resume command",
        )
    return Transition("restart", ["/exit", f"claude --resume {session_id}"], typed=True)


def _build_handoff_transition(payload: JSONDict, title: str) -> Transition:
    if "compact" in payload:
        err("compact", 'forbidden when skill is "handoff"')
    if "clear" not in payload:
        err("clear", 'required when skill is "handoff"')
    if not isinstance(payload["clear"], bool):
        err("clear", "must be true or false")
    if payload["clear"] is True:
        return Transition("clear", [f"/rename {title}", "/clear"], typed=True)
    return Transition("rename", [f"/rename {title}"], typed=False)


def _build_precompact_transition(payload: JSONDict) -> Transition:
    if "clear" in payload:
        err("clear", 'forbidden when skill is "precompact"')
    if "compact" not in payload:
        err("compact", 'required when skill is "precompact"')
    compact_val = payload["compact"]
    ctype = _json_type(compact_val)
    if ctype == "boolean":
        if compact_val is True:
            return Transition("compact", ["/compact"], typed=True)
        return Transition("compact", [], typed=False)
    if ctype == "string":
        require_one_line("compact", compact_val)
        return Transition("compact", [f"/compact {compact_val}"], typed=True)
    err("compact", "must be true, false, or a focus directive string")
    raise AssertionError("unreachable")  # err() always raises


def validate_continuation(payload: JSONDict, skill: str, *, typed: bool) -> str:
    """Return the continuation prompt, or "" when there is none."""
    if skill == "autoname":
        return ""
    if "continue" not in payload:
        err("continue", "required, either null or one line of prose")
    if payload["continue"] is None:
        return ""
    if not isinstance(payload["continue"], str):
        err("continue", "must be null or one line of prose")
    continuation = payload["continue"]
    require_one_line("continue", continuation)
    if continuation.startswith("/"):
        err("continue", "must not begin with `/`")
    if not typed:
        err("continue", "must be null when the transition is not typed")
    return continuation


def _got(value: object) -> str:
    """Render a rejected `action` value: quoted when a string, else its type.

    A non-string action rendered with `f"{value}"` prints a Python repr —
    `True`, not `true` — so the diagnostic names a spelling no JSON producer
    could have sent. Every other type reads better as its type name anyway,
    which is what the neighbouring diagnostics already say.
    """
    if _json_type(value) == "string":
        return f'"{value}"'
    return _json_type(value)


def _reject_unknown_keys(
    field: str, obj: JSONDict, action: str, allowed: tuple[str, ...]
) -> None:
    """Error unless obj carries only "action" and the action's own keys.

    An action object that silently ignores what it does not recognize is the
    defect class the tagged union was opened to close one level down: an agent
    told `must be "clear", got "write"` that corrects only the action leaves
    its `content` in place, and the frame is removed with nothing said.
    """
    extra = sorted(k for k in obj if k != "action" and k not in allowed)
    if not extra:
        return
    takes = (
        "takes no other key"
        if not allowed
        else "takes only " + " and ".join(f'"{k}"' for k in allowed)
    )
    err(field, f'unknown key "{extra[0]}", {{"action": "{action}"}} {takes}')


def validate_task(payload: JSONDict) -> tuple[str, str]:
    """("write", content) or ("clear", "")."""
    if "task" not in payload:
        err("task", 'required, a content string or {"action": "clear"}')
    task = payload["task"]
    ttype = _json_type(task)
    if ttype == "string":
        return "write", cast("str", task)
    if ttype == "object":
        if "action" not in task:
            err("task.action", 'required, a content string or {"action": "clear"}')
        action = task["action"]
        if action == "clear":
            _reject_unknown_keys("task", task, "clear", ())
            return "clear", ""
        err("task.action", f'must be "clear", got {_got(action)}')
    err(
        "task",
        f'must be a content string or {{"action": "clear"}}, got {ttype}',
    )
    raise AssertionError("unreachable")  # err() always raises


def validate_todo(payload: JSONDict) -> tuple[str, str, str, str]:
    """Return the todo action and its content or old/new strings.

    ("write", content, "", ""), ("edit", "", old_string, new_string), ("clear",
    "", "", "") or ("keep", "", "", "").
    """
    if "todo" not in payload:
        err("todo", "required, a content string or an object naming an action")
    todo = payload["todo"]
    ttype = _json_type(todo)
    if ttype == "string":
        return "write", cast("str", todo), "", ""
    if ttype == "object":
        if "action" not in todo:
            err(
                "todo.action",
                'required, a content string or "clear", "keep" or "edit"',
            )
        action = todo["action"]
        if action in ("clear", "keep"):
            _reject_unknown_keys("todo", todo, cast("str", action), ())
            return cast("str", action), "", "", ""
        if action == "edit":
            _reject_unknown_keys("todo", todo, "edit", ("old_string", "new_string"))
            old_string, new_string = _todo_edit_strings(todo)
            return "edit", "", old_string, new_string
        err(
            "todo.action",
            f'must be "clear", "keep" or "edit", got {_got(action)}',
        )
    err(
        "todo",
        f"must be a content string or an object naming an action, got {ttype}",
    )
    raise AssertionError("unreachable")  # err() always raises


def _todo_edit_strings(todo: JSONDict) -> tuple[str, str]:
    """Return the edit action's (old_string, new_string), both required strings.

    Typing them here is what keeps `edit` from being the one arm of the union
    that types nothing: every other arm's payload is a checked string, and an
    unchecked one reaches edited_body's `content.count(old)` as a TypeError,
    which exits 1 and names no field (FR2).
    """
    strings: list[str] = []
    for key in ("old_string", "new_string"):
        if key not in todo:
            err(f"todo.{key}", 'required for {"action": "edit"}')
        ktype = _json_type(todo[key])
        if ktype != "string":
            err(f"todo.{key}", f"must be a string, got {ktype}")
        strings.append(cast("str", todo[key]))
    return strings[0], strings[1]


class FilePlan(NamedTuple):
    """What one half will do to its file, resolved before anything is written.

    A NamedTuple, like Transition beside it, so the record itself is frozen.
    Every plan carrying a manifest line comes from _plan_file, so a plan cannot
    claim a `D` it will not perform; plan_todo's `keep` builds the empty plan
    directly, ahead of that resolver, because FR4 forbids it even a stat.
    """

    act: Literal["write", "remove", "none"]
    path: Path
    body: str
    manifest_lines: list[str]


def edited_body(field: str, path: Path, old: str, new: str) -> str:
    """Return path's content with old replaced by new, first occurrence only.

    Errors, naming field, if old is absent or ambiguous. Returns the replacement
    rather than writing it, which is what lets both err() sites run while a plan
    is still being resolved, ahead of any write (FR2).
    """
    content = path.read_text(encoding="utf-8")
    count = content.count(old)
    if count == 0:
        err(f"{field}.old_string", f"not found in {path}")
    if count > 1:
        err(f"{field}.old_string", f"ambiguous, {count} occurrences in {path}")
    return content.replace(old, new, 1)


def _plan_file(path: Path, rel: str, body: str) -> FilePlan:
    """Resolve one file's plan from its would-be body (FR5/FR6/FR7).

    An empty body is a removal (FR6) — existence is sampled here, before
    anything is written, so a `D` line records only a removal that will actually
    happen. A non-empty body is a write, unconditionally.
    """
    existed = path.is_file()
    if lib.is_empty_body(body):
        if not existed:
            return FilePlan("none", path, "", [])
        return FilePlan("remove", path, "", [f"D {rel}"])
    return FilePlan("write", path, body, [f"W {rel}"])


def plan_task(root: Path, action: str, content: str) -> FilePlan:
    """Resolve the task write or clear to a plan (FR5/FR6/FR7).

    `clear` resolves to the empty string, so it reaches removal through
    _plan_file's own emptiness rule rather than a branch of its own.
    """
    body = "" if action == "clear" else content
    return _plan_file(root / HANDOFF_REL_TASK, HANDOFF_REL_TASK, body)


def plan_todo(root: Path, action: str, content: str, old: str, new: str) -> FilePlan:
    """Resolve the todo write, edit, clear or keep to a plan (FR5/FR6/FR7).

    `keep` short-circuits ahead of _plan_file, straight to the empty plan: it
    must not reach a rule that reads an absent body as a removal, and it takes
    no stat (FR4). `edit` keeps its own explicit file-absent err() ahead of
    edited_body, so the stat _plan_file then takes is deliberate — a
    precondition check and an existence sample are different questions.
    """
    path = root / HANDOFF_REL_TODO
    if action == "keep":
        return FilePlan("none", path, "", [])
    if action == "clear":
        body = ""
    elif action == "edit":
        if not path.is_file():
            err(
                "todo.old_string",
                f"edit requested but {HANDOFF_REL_TODO} does not exist",
            )
        body = edited_body("todo", path, old, new)
    else:
        body = content
    return _plan_file(path, HANDOFF_REL_TODO, body)


def apply_plan(plan: FilePlan) -> None:
    """Perform the write or the unlink a plan names.

    No failure branch.
    """
    if plan.act == "write":
        plan.path.write_text(plan.body, encoding="utf-8")
    elif plan.act == "remove":
        plan.path.unlink()


def write_manifest(root: Path, manifest_lines: list[str]) -> None:
    """Write the manifest, always, even with zero lines.

    bash-post.sh's fast-exit gate is the manifest's mere presence.
    """
    content = "\n".join(manifest_lines) + "\n" if manifest_lines else ""
    (root / ".claude" / "checkpoint-manifest").write_text(content, encoding="utf-8")


def compose_directives(skill: str, root: Path, commit_mode: str) -> tuple[str, str]:
    """Return the (memory, second) directive pair for this boundary."""
    root_s = str(root)
    if skill == "handoff":
        return lib.memory_directive(root_s, commit_mode), lib.todo_boundary(root_s)
    if skill == "precompact":
        return lib.memory_directive(root_s, commit_mode), lib.sdd_directive(root_s)
    return "", ""


def _read_back_drive(drive_path: Path) -> tuple[bool, str]:
    """Read the just-composed sentinel back through handoff_drive_read.

    handoff_drive_read stays bash (unmoved) — the single implementation of the
    sentinel grammar.
    """
    script = (
        f"source {shlex.quote(str(_LIB_SH))}; "
        f"handoff_drive_read {shlex.quote(str(drive_path))} && exit 0; "
        'printf "%s" "$DRIVE_ERR" >&2; exit 1'
    )
    result = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, check=False
    )
    return result.returncode == 0, result.stderr


def compose_sentinel(
    root: Path, transition: Transition, continuation: str, memory: str
) -> str:
    """Write the sentinel and read it back through the bash parser.

    Returns the memory directive, with the arming instruction appended when the
    sentinel holds.
    """
    state = "armed"
    if transition.cmds and memory:
        session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        state = f"held {session_id}"
        memory = memory + "\n\n" + lib.arming_directive()

    drive_path = root / HANDOFF_REL_DRIVE
    sentinel_lines = [state, transition.kind, *transition.cmds]
    if continuation:
        sentinel_lines.append(continuation)
    drive_path.write_text("\n".join(sentinel_lines) + "\n", encoding="utf-8")

    ok, drive_err = _read_back_drive(drive_path)
    if not ok:
        drive_path.unlink()
        err(
            "transition",
            f"composed a sentinel this version cannot read back — {drive_err}",
        )
    return memory


def print_output(memory: str, second: str) -> None:
    """Print the directive output (FR9): memory, second, both, or neither."""
    if memory and second:
        sys.stdout.write(f"{memory}\n\n{second}\n")
    elif memory:
        sys.stdout.write(f"{memory}\n")
    elif second:
        sys.stdout.write(f"{second}\n")


def main() -> int:
    """Run the checkpoint.

    Validate the payload, apply writes, compose the sentinel and directives,
    print them.
    """
    payload = read_payload()
    root = validate_root()
    skill = validate_skill(payload)

    if skill == "autoname":
        validate_autoname_forbidden_fields(payload)
    if skill == "restart":
        validate_restart_forbidden_fields(payload)
    commit_mode = validate_commit_mode(payload, skill)
    title = validate_rename(payload, skill)
    transition = build_transition(payload, skill, title)
    continuation = validate_continuation(payload, skill, typed=transition.typed)

    manifest_lines: list[str] = []
    if skill in ("handoff", "precompact"):
        task_action, task_content = validate_task(payload)
        todo_action, todo_content, todo_old, todo_new = validate_todo(payload)
        task_plan = plan_task(root, task_action, task_content)
        todo_plan = plan_todo(root, todo_action, todo_content, todo_old, todo_new)
        apply_plan(task_plan)
        apply_plan(todo_plan)
        manifest_lines = task_plan.manifest_lines + todo_plan.manifest_lines
    write_manifest(root, manifest_lines)

    memory, second = compose_directives(skill, root, commit_mode)
    memory = compose_sentinel(root, transition, continuation, memory)
    print_output(memory, second)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
