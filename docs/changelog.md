# claude-plugin-dev Changelog

How the design got to its current shape. Each entry is a write-time record of
one change: what moved, and the reasoning available at the time. Entries are
never revised — a dated record is correct forever precisely because it is dated.
The living design is [design.md](design.md); when a decision there is
overturned, it is rewritten in place and the reversal gets an entry here.

Newest first.

- [2026-07-29 — `resume-release`](changelog/2026-07-29-resume-release.md) — the release tail became an idempotent block both `release` and a recovery path run (v0.5.0)
- [2026-07-27 — `check-version.sh`](changelog/2026-07-27-check-version.md) — detects a release that tagged and pushed but never bumped the marketplace (v0.4.1, v0.4.2)
- [2026-07-23 — `prerelease` gate](changelog/2026-07-23-prerelease-gate.md) — `release` binds to a consumer-defined gate; breaking, every consumer adds a recipe (v0.4.0)
- [2026-07-01 — Non-interactive release](changelog/2026-07-01-non-interactive-release.md) — dropped the confirmation prompt and `--yes`; the outer permission gate already asks (v0.3.0)
- [2026-06-11 — Marketplace entry creation](changelog/2026-06-11-marketplace-entry-creation.md) — first publication creates the entry instead of aborting; the bump commit became idempotent (v0.2.1)
- [2026-04-29 — `VERSION` file and marketplace bump](changelog/2026-04-29-version-file-and-marketplace-bump.md) — the toolkit can identify itself inside a subtree, and `release` treats tag + marketplace as one release (v0.2.0)
- [2026-04-27 — Initial extraction](changelog/2026-04-27-initial-extraction.md) — toolkit broken out of handoff and gitmoji, the two release recipes unified (v0.1.0)
