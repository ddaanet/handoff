#!/usr/bin/env python3
"""Resolve the effective handoff root for a session cwd.

When ``cwd`` is inside a linked git worktree of ``project``, returns the
worktree root so each worktree owns its own ``.claude/``; otherwise returns
``project``. Pure filesystem reads, no subprocess. Port of the cwd-safety
plugin's ``_worktree_root`` plus a ``-> project`` fallback.

CLI: ``worktree_root.py <cwd> <project>`` prints the resolved root.
"""

import os
import sys


def _read_gitdir(dotgit_file: str) -> str:
    """Return the absolute gitdir from a linked worktree's ``.git`` file, or "".

    A linked worktree's ``.git`` is a file containing ``gitdir: <path>``. A
    relative path is joined to the file's directory but not normalized; git
    writes absolute gitdir paths in practice, so a relative one simply won't
    match ``project/.git`` and the dir is treated as not-a-worktree (safe).
    """
    try:
        with open(dotgit_file, encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return ""
    for line in content.splitlines():
        if line.startswith("gitdir:"):
            path = line[len("gitdir:") :].strip()
            if not path:
                return ""
            if not os.path.isabs(path):
                path = os.path.join(os.path.dirname(dotgit_file), path)
            return path
    return ""


def _is_under(path: str, parent: str) -> bool:
    """Report whether ``path`` equals ``parent`` or sits inside it (string)."""
    parent = parent.rstrip(os.sep)
    return path == parent or path.startswith(parent + os.sep)


def worktree_root(cwd: str, project: str) -> str:
    """Effective handoff root for ``cwd`` given main project root ``project``.

    Walks up from ``cwd``; the worktree root is the first ancestor whose
    ``.git`` is a *file* whose ``gitdir:`` resolves under ``project/.git``.
    Returns ``project`` on the main tree, a nested standalone repo, an empty
    input, or anything unrecognized.
    """
    if not cwd or not project:
        return project
    git_main = os.path.join(project, ".git")
    d = cwd
    while True:
        if d == project:
            return project
        dotgit = os.path.join(d, ".git")
        if os.path.isfile(dotgit):
            gitdir = _read_gitdir(dotgit)
            if gitdir and _is_under(gitdir, git_main):
                return d
            return project
        if os.path.isdir(dotgit):
            return project
        parent = os.path.dirname(d)
        if parent == d:
            return project
        d = parent


def main() -> None:
    """Print the resolved handoff root for argv's cwd and project."""
    cwd = sys.argv[1] if len(sys.argv) > 1 else ""
    project = sys.argv[2] if len(sys.argv) > 2 else ""
    print(worktree_root(cwd, project))


if __name__ == "__main__":
    main()
