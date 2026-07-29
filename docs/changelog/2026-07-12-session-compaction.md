# Session compaction (2026-07-12)

Compaction intersects the plugin twice: as a *transcript feature* the
extractor must parse, and as a *candidate boundary* the plugin might
serve. The two get opposite answers.

## As a transcript feature: in scope — defect found and fixed

Verified against real transcripts (CC 2.0.74, 12 compactions; corroborated
by current docs): compaction appends to the **same JSONL, same session ID**
— a `type:"system", subtype:"compact_boundary"` entry (`compactMetadata:
{trigger: manual|auto, preTokens}`), the entry chain re-rooted (`parentUuid:
null` plus a `logicalParentUuid` back-pointer), then the summary injected as
a `type:"user"` entry flagged `isCompactSummary: true` but **not** `isMeta`.
That entry passed every extractor filter (`isMeta`, `isSidechain`,
`WRAPPER_PREFIXES` — its text starts "This session is being continued...",
not a known wrapper), so a compaction inside the last-N window inlined a
multi-KB stale summary into the frame as a "user prompt" — violating the
small-frame property and the no-summarisation-layer non-goal at once. Fixed
structurally, same pattern as `isMeta` (see [Extraction
rules](2026-05-19-original-activation-and-loading.md)). Everything else
survives compaction unaided: the JSONL is append-only, so
`handoff_activated()` signals persist, the session pointer stays valid, and
no `/clear`-style bridge is needed.

## As a boundary: non-goal for the task frame

> **Superseded 2026-07-20** (see [One task file, two
> transitions](2026-07-20-one-task-file-two-transitions.md)):
> `SessionStart(compact)` is matched — `load-compact.sh` injects the same
> `handoff_frame` there that `load-handoff.sh` injects at `startup|clear`.
> The staleness argument below held only while the frame could come from a
> *previous* boundary; precompact now writes the file in the turn that arms
> the compaction, so the frame is fresher than the summary rather than older
> than it. The verbatim-tail argument stands and is why the frame carries no
> transcript. Auto-compact remains out of scope.

`SessionStart` deliberately does not match the `compact` source (the
matcher exists and supports `additionalContext`). Two reasons:

- **The mechanical residual crosses natively.** Current compaction
  retains a verbatim tail of recent messages alongside the summary —
  this supersedes the April 2026 research row "Claude Code: summary
  only". Re-injecting extracted last-N prompts would duplicate context
  the harness already kept.
- **The judgment residual cannot be fresh.** The only frame available
  at compact time is the one from the last handoff — a *previous*
  boundary by definition. Re-injecting it glues a stale task statement
  onto a fresher summary: the commit-status defect (2026-06-24)
  generalised to the whole frame.

Auto-compact is fully out of scope: the harness picks the moment
mid-turn (no agent-judgment turn exists), and it cannot be disabled —
only its threshold moved (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`; the
disable requests are open upstream issues). Community consensus since
the 2025 preservation improvements is to leave it on and rely on disk
durability for anything that must survive. That is this plugin's stance
too: durable context belongs in gitlore memory and the task frame, not
in machinery that fights the summariser.

## Manual compact as a wrap-up moment

> **Superseded 2026-07-20** on two of its three exclusions. precompact
> writes `handoff-task.md` ([One task file, two
> transitions](2026-07-20-one-task-file-two-transitions.md): with no durable
> channel, anything verbatim-critical gets crammed into the continuation
> prompt), and it runs the memory probe and commits through it ([precompact
> drives the compaction](2026-07-20-precompact-drives-the-compaction.md):
> the commit can wait, but the conversation it summarises cannot). It also
> drives `/compact` and the continuation rather than telling the user to.
> The rename stays unbundled, and the `PreCompact`-hook rejection stands —
> the compaction is driven from `Stop`, still not from a hook that cannot
> run an agent turn.

A manual `/compact` is a user-chosen milestone — structurally like
`/clear` with lossy continuation instead of a reset. Testing handoff's
wrap-up bundle against it, the components transfer unevenly:

- **Task frame — no** (above; in-session continuity is the summary's
  job, and a frame written at compact time would arm the next
  `SessionStart(startup|clear)` injection with a frame the session
  continued past — stale by construction).
- **Memory flush — yes, the real loss channel.** Durable learnings that
  live only in conversation are paraphrased or dropped by the
  summariser; flushing them to gitlore memory *before* compacting
  preserves fidelity, and the machinery exists whole
  (`handoff-memory-probe` → summarize → approve → commit).
- **Rename — mild yes.** The pre-compact transcript is the richest
  naming input, and `/handoff:autoname` exists for exactly "a session
  worth a name while the main thread stays live".

Decision (revised same day): ship it as **`/handoff:precompact`** — a
thin skill packaging the memory-flush paragraph from the handoff
skill's Step 1, nothing else. No task file (the summary carries the
task), no rename bundled (use `/handoff:autoname` when wanted), and no
memory probe or commit: compaction threatens conversation state only —
disk survives it, so committing can ride any later commit. The probe's
commit dance is wrap-up logic, not pre-compact logic. A `PreCompact`
hook was rejected: hooks are mechanical and the flush is judgment —
`PreCompact(manual)` can annotate or block the compaction but cannot
run an agent turn.

Recorded as a requirement while here (previously implicit in the
skill's shape): in the non-gitlore case the handoff wrap-up completes
in a **single parallel tool-call turn** — the memory probe is
unconditional and batched with the task/autorename writes precisely so
no detection round-trip exists. Any rebalancing of the gitlore seam
(e.g. moving the probe into a gitlore-shipped command behind a
`command -v` lookup — considered and rejected 2026-07-12) must
preserve this.

## Plugin boundary: the handoff/gitlore separation stands

Pulling on the pre-compact thread ("without gitlore, the memory step is
one paragraph — the interesting logic is gitlore's") opened the plugin
boundary. Three restructurings were considered and rejected:

- **Merge handoff into gitlore** — distinct timescales (durable memory
  vs one-transition working state), distinct machinery (git plumbing vs
  session plumbing), asymmetric adoption cost (built-in auto-memory vs
  submodule + commit gates).
- **Move the probe into gitlore** behind a `command -v` lookup — adds
  the detection round-trip the current packaging exists to avoid (the
  single-turn FR above). Verified en route: every *enabled* plugin's
  `bin/` is on PATH, so cross-plugin bare-name invocation does work —
  the mechanism is fine, the extra call is not.
- **gitlore supersedes handoff** (gitlore ships its own
  handoff/precompact/autoname; handoff reduces to the non-gitlore
  case) — attractive as product tiers, but supersession means gitlore
  carries *all* of handoff's machinery (six hooks, `extract.py`, the
  rename watcher), vendored and kept in sync. Duplication cost exceeds
  the benefit.

Standing model: handoff owns the wrap-up including the unconditional
memory-flush step; the probe is its one gitlore seam, and it is a
**mandatory commit point** — a review-commit-push-resolve gate for
gitlore memory, not a suggestion (gitlore's advisory dirty-memory hook
is not a substitute). The skill body is gitlore-free: Step 3 says
"follow the probe's directive" and nothing else, so in the non-gitlore
case the agent never learns gitlore exists. The three-tier framing
survives as *positioning*, not plugin boundaries: ddaa-handoff
(claude.ai summaries), handoff (Claude Code native continuity), gitlore
(versioned memory on top).

## Durable progress files: the precompact probe (2026-07-17)

precompact was memory-only by construction — the task crosses
compaction in the summary. That default is right for a plain
conversation but wrong for a structured execution workflow that keeps a
**durable progress ledger** the summary cannot reproduce. superpowers
SDD is the motivating case: its `.superpowers/sdd/progress.md` records
`Task N: complete (commits <base>..<head>, review clean)` lines and
deferred Minor findings, and the SDD skill itself says to trust that
ledger over post-compaction recollection. A mid-run `/compact` with a
stale ledger is the most expensive SDD failure — completed tasks get
re-dispatched.

Two-part fix, matching the handoff/gitlore split:

- **General line in the skill body** (plugin-agnostic): if the session
  is mid-structured-task with a durable progress/state file, bring it
  current before compacting. Covers *unknown* workflows; carries no
  foreign vocabulary.
- **`handoff-precompact-probe`** (`scripts/precompact-probe.sh` + `bin/`
  shim): the probe owns the plugin-specific vocabulary, exactly as
  `handoff-memory-probe` owns gitlore's. Read-only, silent by default; a
  one-row registry resolves git root (`git rev-parse --show-toplevel`,
  mirroring SDD's own `sdd-workspace`) and, if
  `.superpowers/sdd/progress.md` exists, emits the calibrated flush
  directive. No git root → no known ledger → silent.

> **Corrected 2026-07-26** (see [An orphaned ledger hijacks the
> handoff](2026-07-26-orphaned-ledger.md)): that path is superpowers
> 6.1.1's. 6.2.0 moved the ledger into a per-plan workspace and the flat
> path became a stray the probe must ignore, so the registry now matches
> `.superpowers/sdd/*/progress.md` and requires SDD's identity first line.
> The existence-not-currency exclusion below stands — liveness is
> structural, currency is not.

Named after the *moment* (`precompact`), not the mechanism
(`progress`): the agent runs it opaquely and follows whatever it prints,
with no name-level hint that would prompt it to re-derive on its own —
the same opaqueness the gitlore Step-3 simplification bought.

Two deliberate exclusions. The probe detects a file's **existence**, not
its currency — only the agent, from conversation context, can judge
whether the ledger is current, so the directive says "bring it current"
rather than guessing at staleness. And precompact **still does not run
`handoff-memory-probe`**: committing memory stays wrap-up logic (the
commit rides the following session), so the probe is advisory — a nudge,
not the gitlore probe's mandatory commit gate.

> **Superseded 2026-07-20** (see [precompact drives the
> compaction](2026-07-20-precompact-drives-the-compaction.md)): the second
> exclusion is reversed. precompact composes the memory directive ahead of
> the ledger nudge and commits before the summariser runs, because the
> summary is written from the conversation and after compaction that
> conversation is a paraphrase. The existence-not-currency exclusion stands.

Calibrated against superpowers 6.1.1: the origin note's vocabulary
("in-flight fix-waves", "how to verify an incoming subagent report") was
dropped — those are live controller behaviors, not durable ledger state.
The ledger holds only completed-task lines and deferred Minor findings.

## Session JSONL schema reference

Transcript-parsing defects recur because the format is
reverse-engineered. Researched 2026-07-12: **no authoritative schema
exists** — the official sessions doc states the entry format is
internal to Claude Code and changes between versions. Best maintained
external references (both verified): claude-dev.tools' JSONL format doc
(field-level, practical) and `simonw/claude-code-transcripts` (actively
maintained parser — the code is the reference; its README documents
usage, not the format). The repo's existing stance stands, now with
backing: fixtures must mirror eyeballed real transcripts, and filtering
keys on structural flags (`isMeta`, `isSidechain`, `isCompactSummary`),
never content heuristics.
