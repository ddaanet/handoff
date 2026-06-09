# Branch matrix for scripts/worktree_root.py. tmp_path scaffolds a fake
# linked worktree: a directory whose .git is a *file* containing
# `gitdir: <project>/.git/worktrees/<name>`, mirroring real git layout.
from worktree_root import worktree_root


def _make_project(tmp_path):
    project = tmp_path / "proj"
    (project / ".git" / "worktrees").mkdir(parents=True)
    return project


def _make_worktree(project, name="wt"):
    wt = project.parent / name
    wt.mkdir()
    gitdir = project / ".git" / "worktrees" / name
    gitdir.mkdir(parents=True, exist_ok=True)
    (wt / ".git").write_text(f"gitdir: {gitdir}\n")
    return wt


def test_worktree_root_itself(tmp_path):
    project = _make_project(tmp_path)
    wt = _make_worktree(project)
    assert worktree_root(str(wt), str(project)) == str(wt)


def test_worktree_subdir_drifts_up_to_worktree_root(tmp_path):
    project = _make_project(tmp_path)
    wt = _make_worktree(project)
    sub = wt / "src" / "deep"
    sub.mkdir(parents=True)
    assert worktree_root(str(sub), str(project)) == str(wt)


def test_cwd_is_project_returns_project(tmp_path):
    project = _make_project(tmp_path)
    assert worktree_root(str(project), str(project)) == str(project)


def test_main_tree_subdir_returns_project(tmp_path):
    project = _make_project(tmp_path)
    sub = project / "scripts"
    sub.mkdir()
    assert worktree_root(str(sub), str(project)) == str(project)


def test_dotgit_directory_ancestor_returns_project(tmp_path):
    project = _make_project(tmp_path)
    nested = tmp_path / "nested"
    (nested / ".git").mkdir(parents=True)  # a *directory*, not a worktree file
    sub = nested / "sub"
    sub.mkdir()
    assert worktree_root(str(sub), str(project)) == str(project)


def test_gitdir_outside_project_git_returns_project(tmp_path):
    project = _make_project(tmp_path)
    wt = project.parent / "rogue"
    wt.mkdir()
    (wt / ".git").write_text("gitdir: /somewhere/else/.git/worktrees/x\n")
    assert worktree_root(str(wt), str(project)) == str(project)


def test_relative_gitdir_treated_as_non_worktree(tmp_path):
    # git writes absolute gitdir paths; a relative one is not normalized and
    # falls back to project (documented limitation, matches cwd-safety).
    project = _make_project(tmp_path)
    wt = project.parent / "rel"
    wt.mkdir()
    (wt / ".git").write_text("gitdir: ../proj/.git/worktrees/rel\n")
    assert worktree_root(str(wt), str(project)) == str(project)


def test_empty_cwd_returns_project(tmp_path):
    project = _make_project(tmp_path)
    assert worktree_root("", str(project)) == str(project)


def test_unrelated_cwd_no_git_returns_project(tmp_path):
    project = _make_project(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    assert worktree_root(str(elsewhere), str(project)) == str(project)
