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


def worktree_root(cwd: str, project: str) -> tuple[str, str]:
    """Effective handoff root for ``cwd``, and the branch that produced it.

    Walks up from ``cwd``; the worktree root is the first ancestor whose
    ``.git`` is a *file* whose ``gitdir:`` resolves under ``project/.git``.
    Returns ``project`` on the main tree, a nested standalone repo, an empty
    input, or anything unrecognized.

    The second element labels which branch was taken, so a caller can tell the
    cases the root alone collapses together:

    ``inside``     cwd is ``project`` or sits under it (including a nested
                   repo or submodule — containment wins over the branch the
                   walk took, or ``cd memory/`` would read as drift);
    ``worktree``   cwd is in a linked worktree of ``project``;
    ``foreign``    cwd is in some other repo, or a worktree of one;
    ``unrelated``  cwd is in no repo at all.

    The last two are drift: cwd has left the launch repo, while the root — and
    every handoff file under it — has not.
    """
    if not cwd or not project:
        return project, "inside"
    git_main = os.path.join(project, ".git")
    d = cwd
    branch = ""
    while not branch:
        if d == project:
            return project, "inside"
        dotgit = os.path.join(d, ".git")
        if os.path.isfile(dotgit):
            gitdir = _read_gitdir(dotgit)
            if gitdir and _is_under(gitdir, git_main):
                return d, "worktree"
            branch = "foreign"
        elif os.path.isdir(dotgit):
            branch = "foreign"
        else:
            parent = os.path.dirname(d)
            if parent == d:
                branch = "unrelated"
            else:
                d = parent
    return project, "inside" if _is_under(cwd, project) else branch


def main() -> None:
    """Print the resolved handoff root for argv's cwd and project.

    Two lines: the root, then the branch label. ``handoff_root`` in
    ``scripts/_lib.sh`` reads both and prints only the first, so its own stdout
    contract — the root alone — is unchanged.
    """
    cwd = sys.argv[1] if len(sys.argv) > 1 else ""
    project = sys.argv[2] if len(sys.argv) > 2 else ""
    root, branch = worktree_root(cwd, project)
    print(root)
    print(branch)


if __name__ == "__main__":
    main()
