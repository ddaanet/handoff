# 2026-07-29 — `resume-release` completes a half-landed release (v0.5.0)

`check-version.sh` (2026-07-27) taught the toolkit to *detect* a release that
tagged and pushed but never bumped the marketplace, and to refuse to start a new
release on top of one. It had no answer for the repo already in that state. The
guard was correct and the gap was that nothing satisfied it except hand-editing
another repository.

Observed live releasing `gitlore` 0.4.3 on 2026-07-28. `just release patch`
passed `prerelease` and `check-version`, bumped `plugin.json`, committed and
tagged — then `git push` was rejected by gitlore's own pre-push hook, because a
shared memory tier had diverged from its remote. The recipe died there under
`set -e`: after the irreversible commit and tag, before the tag push. Finishing
it meant `git push`, `git push origin v0.4.3`, `gh release create`, and a
hand-written `jq`/`mv`/`commit`/`push` against the marketplace repo — the one
step with no tooling at all. The toolkit's own `v0.4.1` failed in the same
window: a `VERSION` bump commit with no tag.

Three approaches were rejected before this one. Re-running `just release patch`
is blocked by the `check-version` pre-flight, by design. Forcing past the guard
reads the version from the *manifest*, which is already bumped, so it ships the
version after the interrupted one — burning a version number and leaving the
interrupted release permanently absent from the marketplace. Editing
`marketplace.json` alone clears `check-version` but then trips `release`'s
clean-tree check on `$MARKETPLACE_DIR`; the bump has to be committed and pushed
either way.

What landed: the last four steps of a release — push branch, push tag, GitHub
release, marketplace bump — became one idempotent block that both `release` and
a new `resume-release` run, each step probing remote state (`git ls-remote` for
the branch and tag, `gh release view` for the release, `ls-remote` against the
marketplace repo's own origin for the marketplace push) before acting. Resume takes its version
from the manifest and requires the local tag to exist, so it completes a release
and never starts one. A remote tag at a different sha is an error, never a
force-push. `resume-release` has no `prerelease` dependency: the gate already
passed before the interruption, and making recovery cost a paid gate is how you
get people finishing releases by hand instead.

The flow moved out of `release.just`'s recipe body into `plugin-dev/release.sh`
to buy shellcheck coverage, offline end-to-end tests against real git repos with
a stubbed `gh`, and the removal of the just/bash quoting seam. `release.just`
shrank to two one-line wrappers.

Building it turned up four defects in the implementation plan and one in the
shipped code. Two mutation-table entries proved nothing when actually run — one
aborted on an unbound variable under `set -u` before reaching the code it meant
to break, the other corrupted the scenario's own setup step so the assertion
could not discriminate. A third mutation's `grep` pattern never matched `just
--dry-run`'s quoted output. The code defect: the new argument dispatch called
`die` from a position above `die()`'s definition, so an unknown flag exited 127
with `die: command not found` instead of the usage message — shellcheck clean,
and uncovered by any test until one was added. All four were caught by insisting
that every assertion be observed failing before it is trusted.

The whole-branch review then found the same class of bug in the feature itself.
The marketplace step was the one tail step whose "already done" probe read the
working tree instead of the remote, so a marketplace commit whose push was
rejected — the motivating scenario, one repository over — left the next
`--resume` with nothing staged, skipping the push and reporting the release
complete. A silent false success in the recovery tool, on the failure it exists
to recover from. Committing and pushing became two questions with two probes,
and the test suite grew a scenario that puts the rejecting hook on the
marketplace repo rather than the plugin repo. It went from six scenarios to
twelve; the four added beyond that one cover the never-move-a-published-tag
refusal, resume from first publication, and the argument shapes the new
dispatcher introduced.

See "Recovery: `resume-release` and the shared release tail" in
[design.md](../design.md).
