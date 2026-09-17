# Memory moves inside the deciding step (2026-09-17)

`skills/handoff/SKILL.md` opened its protocol with "Make zero tool calls
before invoking `handoff-checkpoint`", then placed Step 2, "Update memory",
between the two deciding steps it governed. Writing memory is tool calls, so
an agent following the steps in order broke the rule the protocol stated
first, and an agent honouring the rule had no sanctioned place to write
memory before the checkpoint — which it must, since the checkpoint's memory
directive keys on the submodule being dirty.

Steps 1 and 3 had no reason to be separate once memory was out from between
them: both decide from context, and Step 3 ended in the checkpoint call. They
collapse into one step, in this order: decide the transition, continuation
and commit answer; capture memory; decide title, task and todo; run the
checkpoint. Memory is written before the checkpoint call, and after the
commit answer because that answer sets the tense memory bodies are written
in. The prohibition names memory writes as its one exception. The directive
and closing-line steps renumber to 2 and 3.

A skill review of the collapsed step found a second contradiction the old
layout had hidden: a commit the ask implies was to land "before this call
when nothing holds the sentinel back", which is Bash calls ahead of the
checkpoint. That placement was also wrong on its own terms — a commit ahead
of the checkpoint cannot carry the handoff files the checkpoint stages. The
commit now comes after the checkpoint and before the transition is armed:
before the turn ends when no directive holds it, before `handoff-approved`
when one does. Nothing was lost by the move, since `Stop` is what arms. It
now sits in Step 2, beside the directive that decides which of those two
applies, rather than after the heredoc, where it read as a step of its own.
`skills/precompact/SKILL.md` had the same "before this call" wording and
takes the same fix, plus the memory-tense clause its step 2 had dropped.

The rest of the pass cut rationale that changed nothing the agent does —
the introduction's paragraph on why a clear is the cheaper reset (the
plugin's thesis, carried by `docs/design.md`), reasons restated by an
anti-pattern or by the seam section, and rules stated once per template.
The templates moved out of the closing-line step into their own section.
The body went from 2127 words to 1799, frontmatter excluded, which settles
the open question of the ≤2000-word guideline.
