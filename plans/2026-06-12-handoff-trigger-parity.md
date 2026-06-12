# handoff Trigger Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the standalone `handoff` skill the same canonical trigger surface as the extracted `ddaa-handoff` / `ddaa-passation`, so whichever handoff provider a project enables responds to the same vocabulary; and document the "enable exactly one provider" rule.

**Architecture:** The two handoff products are interchangeable implementations of one per-project slot. Parity is safe only because they are mutually exclusive (never both enabled). This plan touches only the `handoff` skill's `description` frontmatter and the README — no Python, hooks, or behavior change. The heavy `precommit` suite (mypy, ty, ruff, bats, pytest) must stay green, which here just proves the markdown edits didn't break anything.

**Tech Stack:** Markdown skill frontmatter, `just`, the handoff repo's `precommit` gate. Released via the imported single-plugin `release.just`.

**Companion plan:** `/Users/david/code/skills/docs/plans/2026-06-12-ddaa-handoff-extraction.md` defines the same canonical EN set and must land for the parity to mean anything.

**Canonical EN trigger set** (union of both skills' current triggers, kept whole):
`/handoff`, `handoff`, `save handoff`, `save context`, `prepare handoff`, `write handoff`, `before /clear`, `before I clear`, `clear handoff`, `discard handoff`, `clean handoff`, `finalize`, `wrap up`, `I'm done`, `summarize so I can continue tomorrow`, `conversation too long`, `let's pick this up in a new chat`, `end`, `goodbye`.

> The `autoname` skill cross-references `"save handoff"`, `"before /clear"`, `"wrap up"`, `"I'm done"` — all retained in the canonical set, so `autoname` needs **no** change.

---

## File Structure

**Modified:**
- `skills/handoff/SKILL.md` — frontmatter `description` adopts the canonical EN set (adds `/handoff`, `handoff`, `summarize so I can continue tomorrow`, `conversation too long`, `let's pick this up in a new chat`, `end`, `goodbye` to the current list).
- `README.md` — a note under `## Scope` stating the mutual-exclusion rule.

**Unchanged:** `skills/autoname/SKILL.md`, all hooks/scripts/tests.

---

## Task 1: Adopt the canonical EN trigger set in the handoff description

**Files:**
- Modify: `skills/handoff/SKILL.md` (frontmatter `description` — one line)

- [ ] **Step 1: Replace the description line**

In `/Users/david/code/handoff/skills/handoff/SKILL.md`, replace the single `description:` line with:

```
description: This skill should be used when the user asks to "save handoff", "save context", "prepare handoff", "write handoff", "before /clear", "before I clear", "clear handoff", "discard handoff", "clean handoff", "finalize", "wrap up", "I'm done", "/handoff", "handoff", "summarize so I can continue tomorrow", "conversation too long", "let's pick this up in a new chat", "end", "goodbye", or otherwise signals imminent `/clear` or end-of-task. Writes a short markdown task file when there is residual state worth preserving across `/clear`; otherwise leaves nothing in place.
```

- [ ] **Step 2: Confirm the new triggers are present and frontmatter is intact**

Run:
```bash
f=/Users/david/code/handoff/skills/handoff/SKILL.md
grep -q '"goodbye"' "$f" && grep -q '"/handoff"' "$f" && grep -q '"conversation too long"' "$f" \
  && head -1 "$f" | grep -qx -- '---' && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git -C /Users/david/code/handoff add skills/handoff/SKILL.md
git -C /Users/david/code/handoff commit -m "✨ handoff: trigger parity with ddaa-handoff (canonical set)"
```

> If the commit prints `gitlore: memory merge prepared`, run the `gitlore:resolve` skill — this repo's parent commit gates the memory submodule. The markdown edit itself adds no memory, so a clean pass is expected.

---

## Task 2: Document the "enable exactly one provider" rule in the README

**Files:**
- Modify: `README.md` (insert under `## Scope`, after the table's "See DESIGN.md" line, before `## Requirements`)

- [ ] **Step 1: Insert the mutual-exclusion note**

In `/Users/david/code/handoff/README.md`, after the line:
```
See [`DESIGN.md`](DESIGN.md) for the research and analysis behind this
split.
```
add a blank line and:
```markdown
### Choosing a handoff provider

This is the lightweight, local pre-`/clear` snapshot. A separate plugin,
`ddaa-handoff` (and its French `ddaa-passation`), provides a heavier
end-of-session *summary* delivered to Notion when available. They share
the same trigger phrases on purpose, so the same words work whichever you
pick — therefore **enable exactly one handoff provider per project**.
Enabling both reloads the collision this split was made to remove.
```

- [ ] **Step 2: Confirm the note landed**

Run: `grep -q 'enable exactly one handoff provider' /Users/david/code/handoff/README.md && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git -C /Users/david/code/handoff add README.md
git -C /Users/david/code/handoff commit -m "📝 README: document enable-exactly-one-handoff-provider rule"
```

---

## Task 3: Verify the full precommit suite stays green

The change is markdown-only; this task proves it.

- [ ] **Step 1: Run precommit**

Run: `( cd /Users/david/code/handoff && just precommit )`
Expected: ends with `ok` (jq lints, shellcheck, ruff, docformatter, mypy, ty, bats, pytest all pass — unchanged from before, since no code moved).

- [ ] **Step 2: Confirm clean tree**

Run: `git -C /Users/david/code/handoff status --porcelain`
Expected: nothing printed (both commits landed; release refuses a dirty tree).

---

## Task 4: Release — **run by David**

The handoff plugin has its own single-plugin `release.just`; the trigger-surface expansion is a feature → **minor** bump (0.6.2 → 0.7.0). Release pushes a tag, a GitHub release, and the marketplace bump, so David runs it.

- [ ] **Step 1: Release** (David, in a terminal)

```
cd /Users/david/code/handoff && just release minor
```
Expected: bumps `plugin.json` 0.6.2 → 0.7.0, commits `release: 0.7.0`, tags, pushes, GitHub release, bumps + pushes the `handoff` marketplace entry.

- [ ] **Step 2: Verify**

Run:
```bash
git -C /Users/david/code/handoff describe --tags --abbrev=0
jq -r '.plugins[] | select(.name=="handoff") | .version' /Users/david/code/claude-plugins/.claude-plugin/marketplace.json
```
Expected: `v0.7.0`; marketplace `handoff` entry at `0.7.0`.

---

## Sequencing note

Land this plan **after** (or alongside) the extraction plan. On its own it harmlessly widens the standalone handoff's triggers; its purpose is only realized once `ddaa-handoff`/`ddaa-passation` exist and projects choose one provider.
