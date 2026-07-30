# 2026-07-29 — Driven transitions

Splits the drive-the-TUI half out of `precompact` into its own skill, adds
the symmetric skill for the `/clear` boundary, and replaces the three
one-off TUI drivers with a single armed-transition mechanism that both
depend on. Three skills become five; nine hooks become eight; three
watchers become one walker.

## The defect

`precompact` did two jobs its name claimed only the first of: it prepared
for a compaction, and it drove one. Three consequences.

**There was no prepare-only path for the compact boundary.** An operator who
wanted memory flushed and the task file written, and then to type `/compact`
themselves, had no skill for it. And the driving half's contract did not
hold everywhere it ran: outside tmux `stop-compact.sh` emitted the two lines
to paste, which the skill body it ran under listed as an anti-pattern —
"telling the user to run `/compact`" — while asserting that "invoking
precompact **is** the authorization to compact".

**`handoff` had no driven counterpart.** A mid-task context reset — clear
the window, keep the frame, carry on — is a routine need with no support:
the user typed `/clear` by hand and then retyped a resumption prompt into
the fresh session, which is exactly the typing `precompact` existed to
eliminate at the other boundary.

**The asymmetry was unprincipled.** Both boundaries re-inject the same frame
(`handoff_frame()`, shared by both loaders precisely so they cannot drift).
One was driven end to end and the other was not, for no reason in the
design.

And one that only surfaced on trying to add the fourth entry point:

**The armed transition was a singleton modelled as N files.** One composer,
one session, at most one transition in flight — but the transition's
identity lived in the *filename* (`autorename`, `autocompact`), so the
invariant had nowhere to live and each instance cost a full parallel
pipeline: a constant pair, a validator, a `Stop` arm, a watcher, a failure
channel, a stale sweep. At two instances that duplication was affordable.
The third is where it stopped being.

## What the split does and does not claim

The 2026-07-20 change went the other way deliberately, and its argument
stands: **continuation is intrinsic to compacting.** Nobody compacts before
a `/clear` or before stopping, so invoking a compact-boundary skill is
already the decision to compact *and continue*, and stopping short of it
just made the operator type two things the skill had already worked out.

That argument is about intent, and the split does not touch it. What it does
not establish is that the *agent* must be the one typing — which is a
capability question, is there a tmux pane, and nothing else.

It is not a question of whether the operator wants to see the memory writes
before paying for a compaction. The gitlore gate is inside both prepare-only
skills already: it prints the memory submodule's `git status`, requires the
summary be presented and approved before any file is written, and the arming
rule forbids the sentinel from sharing a turn with that question. Reading
the writes first is not a preference the split serves — it is mandatory and
it already happens.

So the claim is about **naming honesty**, not capability. The compact
directive and the continuation prompt are worth having with no pane to type
them into — the operator pastes them — and authoring them is exactly what
`compact-continue` adds. `precompact` under-delivered against its own name
because it also drove; reduced to preparation it is honest, and the driven
skill's name states the increment.

Both prepare-only skills still end aimed at continuation. They just hand
over the keystrokes.

## The four entry points

| boundary | prepare only | prepare + drive |
|---|---|---|
| compaction | `precompact` | `compact-continue` |
| clear | `handoff` | `handoff-continue` |

`autoname` is unchanged in scope — rename only, neither boundary.

The names are the plugin's own vocabulary: `docs/design.md` already
described the flow as *commit memory → compact → continue*. The conjunction
stays in the prose and out of the name: the identifier is the boundary and
the ending, and `and` distinguishes nothing. `precompact-continue` would
name the preparation twice, so the compact row's driven name is built on the
command rather than on its sibling.

The two skills at a boundary are triggered apart by vocabulary, not by
inference from the situation:

| phrasing | skill |
|---|---|
| "prepare clear", "end", "handoff" | `handoff` |
| "continue after clear", "continue in new session" | `handoff-continue` |
| "prepare compaction", "precompact" | `precompact` |
| "compact and continue", "do this after compact" | `compact-continue` |

The vocabularies are disjoint on the word that carries the decision —
*prepare*/*end* against *continue* — and the bare boundary word falls to the
prepare-only skill. An operator who wants the other default sets it in a
user memory or a `CLAUDE.local.md`. The plugin ships no nudge either way:
that default is one operator's habit, not a property of the boundary.

`handoff-continue` is not compaction's poor cousin. The plugin's thesis is
that the frame is the irreducible residual, and a driven clear is that
thesis applied to a mid-task reset: no summarisation cost, and none of the
cumulative accuracy loss every compaction family acknowledges. For a session
with a well-maintained task file it is the better reset. What it gives up is
everything the frame does not carry.

## The mechanism

A driven transition is **a sequence of lines to type, and the
`SessionStart` source that confirms the transition happened.**

| kind | typed before | typed after | confirming source |
|---|---|---|---|
| `rename` | `/rename <title>` | — | — |
| `compact` | `/compact [directive]` | continuation prose | `compact` |
| `clear` | `/rename <title>`, `/clear` | continuation prose | `clear` |
| `compact` (prepared) | — | — | `compact` |

One sentinel, `.claude/autodrive`. Line 1 is the kind; the kind fixes the
shape, so the remaining lines need no separator and each kind keeps its own
validation rules — which genuinely differ, and are the reason the first
draft reached for siblings.

```
clear
/rename Driven Transitions Design
/clear
pick up the driven-transitions implementation per the task file
```

The lines are the literal keystrokes, including `/rename` and `/clear`.
That is the inversion the singleton buys: while the filename named the
transition, writing the command down was ceremony; now it is the content,
and the walker must not know which command any kind uses. Validation still
anchors it — the *n*th line of kind *k* must begin with the expected command
literal, so the file cannot be made to type something else.

### Confirmation dispatches on the command, not the kind

| line | confirmed by |
|---|---|
| `/rename <t>` | a `custom-title` transcript entry with `customTitle == <t>` |
| `/compact`, `/clear` | `.pending` disappearing, which the confirming `SessionStart` does |
| prose | a genuine user-prompt transcript entry |

Dispatching on the command is what makes `/rename` work in two kinds with
two different fates — terminal under `rename`, followed by `/clear` under
`clear`. It also carries the recognition check for free: any line beginning
`/` gets the type-read-back-Enter path, prose gets the direct one.

The `custom-title` entry closes the last pane-reading confirmation in the
plugin. The old rename watcher grepped the pane for the title's first 20
characters, which matches whenever the title is on screen for any other
reason — the composer's own echo, the skill's reply naming the title it
chose. Verified against a live transcript: `/rename X` writes one
`{"type":"custom-title","customTitle":"X"}` entry, and the harness's own
auto-titling writes `type: "ai-title"`, a distinct type, so an exact match
cannot false-positive on it.

All three primitives became predicates. The existing pair `exit`ed from
inside a helper, which is only safe as a watcher's final statement — the
sole reason the first draft needed a terminal and a non-terminal form of
each. One walker deciding failure for the whole sequence removes the
distinction: predicates return, `watcher_fail` is called once, at the top.

### The walker

`drive-when-idle.sh` replaces `compact-when-idle.sh`, `rename-when-idle.sh`
and `continue-when-idle.sh`:

1. `wait_for_idle`; fail if `is_typing`.
2. Type the line. If it begins `/`: `send-keys -l` with no Enter, read back
   `is_unknown_command`, `C-u` and fail if the TUI refused it, else Enter.
3. Confirm by the command's primitive. On failure, stop — the remaining
   lines are never typed, which is what makes a failed `/rename` under kind
   `clear` cost a wrong title and nothing more.
4. More lines? Back to 1.

Step 4 is not decoration: confirming a line can take minutes
(`CONSUME_TIMEOUT` is 300s) and the pane is live throughout, so idleness
established before it says nothing about now. `wait_for_idle` falls through
when it times out — `is_typing` is the hard gate, and a pane busy without a
composed prompt is typed into eventually — so what the re-gate buys is a
*delay*, not a suppression, and that is what its test asserts.

### The prepare-only compact path still re-injects the frame

`load-compact.sh` returns before assembling the frame when there is no
pending file, so a hand-typed `/compact` would re-inject nothing. The
prepare-only skill therefore arms a sentinel with an *empty* line sequence:
nothing is typed, but the transition is expected, and the loader's existing
gate fires. This is the price of honouring the 2026-07-20 argument rather
than overruling it.

The gate itself does not change — injecting on any compaction whose frame
merely exists was considered and rejected; see `docs/design.md`.

## Skill bodies: delegation, not duplication

The judgment is per-boundary, not per-drive-mode. Commit awareness, memory
capture, the task/todo drafting rules, the seam between what belongs in the
file and what belongs in the prompt — all of it is identical whether or not
the agent types the command afterwards.

So it stays in one file per boundary. `handoff/SKILL.md` and
`precompact/SKILL.md` keep the full protocol; the two driven skills are
short bodies that execute the sibling's protocol by reference and then arm.
The precedent existed: `precompact/SKILL.md` already sent the reader to
`../handoff/SKILL.md` for the templates. The file-vs-prompt seam moved there
too, next to the templates, since it is guidance on what goes in a file
versus what goes in a prompt and both driven skills read that file.

The cost is one extra file read per driven invocation. That is the right
trade against two drifting copies of the load-bearing prose — the
commit-awareness rule and the file-vs-prompt seam are the paragraphs the
whole design rests on, and a design where they exist twice is a design where
they will eventually disagree.

`handoff-continue` inherits one thing `handoff` does not have: the arming
discipline. `handoff` arms nothing, so it carries neither *never in the same
turn as a question the directive requires* nor *the commit lands before the
sentinel is written*. Both apply to a driven clear and neither is inherited.
The normal path is safe by construction — `handoff-continue` runs after
`handoff` has settled the gitlore gate — but the rules exist for the cold
invocation, where dirty memory raises an approval question that ends the
turn, and a sentinel written alongside it clears away the conversation the
answer applies to.

## The payload's `skill` field grows to four values

`checkpoint.sh` validated `skill` as one of `handoff` or `precompact`, and
required `rename` under the former. `handoff-continue` needs `handoff`'s
directive composition without a `rename` — the title belongs in the
sentinel. So `skill` takes four values and names the skill again, honestly.
The directive composition keys on the **boundary** derived from it:

| `skill` | boundary | `rename` |
|---|---|---|
| `handoff` | clear | required |
| `handoff-continue` | clear | forbidden |
| `precompact` | compact | forbidden |
| `compact-continue` | compact | forbidden |

Boundary decides what `checkpoint.sh` composes — memory directive then todo
suppression for clear, memory directive then SDD ledger nudge for compact —
so the two skills at each boundary cannot drift in what they tell the agent.

The alternative was to keep two values and make `rename` merely optional
under `handoff`, at zero cost to the enum or the test matrix. What that
loses is the check that a `handoff` invocation which forgot its title is an
error rather than a silent non-rename, and that check is worth four values.

`checkpoint.sh`'s `rename` write now emits the two-line `rename`-kind
sentinel rather than a bare title, flattening whitespace as it goes:
`bash-post.sh` used to do that at consume time, and with the sentinel
written in its final form there is no consumer left to. That hook loses its
rename spawn entirely and keeps only manifest staging.

## Non-tmux

Both driven skills degrade the way `stop-compact.sh` already did —
`stop-drive.sh` emits the sentinel's lines for the operator to paste, in
order. That stays the supported answer: the pane decides who types, not
which skill is right. Capability is settled at `Stop`, from
`TMUX`/`TMUX_PANE`, long after the skill body has run, so it was never
something a skill could branch on. An operator with no pane who wants a
compact directive and a continuation prompt still invokes
`compact-continue`; the prepare-only skills author neither line and cannot
stand in.

That also settled a question the design carried for a while about whether
the prepare-only skills should print the pasteable form themselves. They
should not: `stop-drive.sh` is the single producer, from the sentinel, in
order — and `precompact` has no lines to print in the first place.

## What was measured

Against a throwaway workspace whose only hook logged the raw `SessionStart`
payload, 2026-07-30:

- `/clear` mints a new session id and a new transcript file. The startup
  session was `1a8d2bf3…`; the `clear` payload reported `85b5eb48…`, and a
  second `.jsonl` appeared beside the first.
- `SessionStart(clear)`'s `transcript_path` is the **new** session's, and
  the file already exists when the hook runs. (The payload omits `model`,
  which `startup` carries; nothing here reads it.)
- `transcript_prompt_count` against that path baselines at 0 and reaches 1
  when a prose line is submitted into the fresh session.

So `load-handoff.sh` exports `HANDOFF_TRANSCRIPT` from its own payload
exactly as `load-compact.sh` does, and the after-line's confirmation needs
nothing the compact path did not already need. The same pane confirmed the
`custom-title` primitive above.

The full design record, including every rejected alternative weighed on the
way, is `plans/2026-07-29-driven-transitions-design.md`.
