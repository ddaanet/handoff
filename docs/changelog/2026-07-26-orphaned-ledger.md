# An orphaned ledger hijacks the handoff (2026-07-26)

`probe_ledger_path` decided a workflow-owned ledger existed by testing one
path — `.superpowers/sdd/progress.md`. That was superpowers SDD's layout
through 6.1.1. As of 6.2.0 each plan owns a git-ignored **workspace**
directory, `.superpowers/sdd/<plan-basename>/progress.md`, and the skill
names the flat path explicitly as *another plan's progress, to be left in
place*. The one path the probe treated as authoritative is the one path SDD
treats as a stray — and nothing removes it: the lifecycle deletes a plan's
*workspace* when the final whole-branch review is clean, and a flat-path file
is in no workspace. The tree is git-ignored, so it never shows in
`git status` either. Only `git clean -fdx` reaches it.

Observed 2026-07-25 in `/Users/david/code/micro`, which carried a
hand-rolled `.superpowers/sdd/progress.md` headed `# ghmem — progress (C2
COMPLETE…)` from a plan that had landed the day before. A session running no
SDD at all — a read-only statistical calibration — had `handoff-todo.md`
suppressed by that file and was told to bring "the ledger" current. It
complied: unrelated findings appended to a ledger whose header claims a
different plan, and the todo file it had already written deleted.

**The harm is the suppression, not the nudge.** `handoff-todo.md` is the half
of the frame that survives a `/clear`; deferring to an abandoned ledger risks
losing the real remainder or believing a stale one — precisely the failure
the registry's own comment warns about ("two ledgers drift, and the stale one
gets believed"), inverted.

So the property to detect is **liveness, not presence**, and it takes three
things:

- **The current layout.** Match `.superpowers/sdd/*/progress.md`. The flat
  path stops counting entirely. Accepting it "for back-compatibility" would
  be honouring the bug, since the current skill guarantees such a file is
  somebody else's leftover.
- **SDD's identity first line**, `# SDD ledger — plan: ` (the em dash is
  literal in SDD's format). This is what separates a live ledger from a
  hand-rolled file that happens to sit in the right place, and it costs one
  `read`. A near-miss fails open — no ledger found means `handoff-todo.md`
  gets written, which is the safe direction.
- **A deterministic choice among several.** An abandoned run and a live one
  both leave a workspace. Most-recently-modified wins: it is the honest
  signal for the one in play, where glob order is only alphabetical. Equal
  mtimes fall back to glob order. Plan-scoping does not make the abandoned
  case impossible, so the tiebreak is mitigation, not a cure.

Checking that the *named plan file* still exists was considered as a fourth
signal and rejected as a gate: it false-negatives on a plan that landed and
was tidied away. Available as a tiebreak if the identity line alone proves
insufficient.

The registry stays the single source of layout truth, and now actually is
one: `probe_sdd_directive` had hardcoded the flat path in its directive text
rather than interpolating `probe_ledger_path`'s output — tolerable with one
fixed path, impossible with a glob. Both consumers interpolate.

The probe remains advisory and read-only. A stale workspace is another
workflow's file, never ours to delete or rewrite however abandoned it looks;
deleting the offending file in `micro` fixed one repo, and any repo with an
abandoned or pre-6.2.0 SDD run reproduces this. Dropping the suppression
altogether and always writing `handoff-todo.md` was also rejected — the
two-ledgers-drift rationale is sound, and the defect was in the detection,
not the policy.
