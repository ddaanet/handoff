# Anchor Multi-Line Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show up to 7 lines of assistant anchor text in full; collapse ≥8-line turns to first 3 + `[…]` + last 3 (always hiding ≥2 lines); remove the stale 120-char line truncation from the text branch.

**Architecture:** All changes are inside `scripts/extract.py` (new constants, new helper, two modified functions) and `tests/extract-test.sh` (one new scenario, five updated assertions). A new fixture `tests/fixtures/anchor-multiline.jsonl` drives the new scenario.

**Tech Stack:** Python 3, bash test harness (`tests/extract-test.sh`), `just precommit`

---

## File map

| File | Change |
|---|---|
| `scripts/extract.py` | Add 3 constants; add `clamp_anchor_lines`; modify `anchor_for` text branch; modify `emit` anchor rendering |
| `tests/fixtures/anchor-multiline.jsonl` | New fixture — 4 user prompts with 3-, 7-, and 8-line assistant text anchors |
| `tests/extract-test.sh` | New test scenario; update 5 existing anchor assertions to new format |

---

### Task 1: Write the failing tests (red)

**Files:**
- Create: `tests/fixtures/anchor-multiline.jsonl`
- Modify: `tests/extract-test.sh`

- [ ] **Step 1: Create fixture**

`tests/fixtures/anchor-multiline.jsonl` — 4 user prompts; anchored by a 3-line, 7-line, and 8-line assistant text turns respectively (first prompt has session-start anchor):

```jsonl
{"type":"user","isSidechain":false,"message":{"role":"user","content":"first prompt no prior assistant"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ANCHOR3_L1\nANCHOR3_L2\nANCHOR3_L3"}]}}
{"type":"user","isSidechain":false,"message":{"role":"user","content":"prompt after 3-line anchor"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ANCHOR7_L1\nANCHOR7_L2\nANCHOR7_L3\nANCHOR7_L4\nANCHOR7_L5\nANCHOR7_L6\nANCHOR7_L7"}]}}
{"type":"user","isSidechain":false,"message":{"role":"user","content":"prompt after 7-line anchor"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ANCHOR8_L1\nANCHOR8_L2\nANCHOR8_L3\nANCHOR8_MIDDLE_DROP_4\nANCHOR8_MIDDLE_DROP_5\nANCHOR8_L6\nANCHOR8_L7\nANCHOR8_L8"}]}}
{"type":"user","isSidechain":false,"message":{"role":"user","content":"prompt after 8-line anchor"}}
```

- [ ] **Step 2: Add new scenario to `tests/extract-test.sh`**

Insert before the final `if (( failures > 0 ))` block:

```bash
# anchor-multiline.jsonl: assistant text anchors with 3, 7, and 8 lines.
# 3-line and 7-line: all lines shown (≤ ANCHOR_LINE_LIMIT=7).
# 8-line: first 3 + [...] + last 3, two middle lines absent.
# Format change: **after** text (no closing **).
echo "=== anchor-multiline (multi-line anchor display) ==="
out_dir="$tmp/anchor-multiline"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
python3 scripts/extract.py tests/fixtures/anchor-multiline.jsonl "$out" > /dev/null

# 3-line anchor: all 3 lines shown, no truncation.
assert_contains "$out" "**after** ANCHOR3_L1" "anchor-multiline: 3-line L1"
assert_contains "$out" "ANCHOR3_L2" "anchor-multiline: 3-line L2"
assert_contains "$out" "ANCHOR3_L3" "anchor-multiline: 3-line L3"

# 7-line anchor: all 7 lines shown (boundary — exactly ANCHOR_LINE_LIMIT).
assert_contains "$out" "**after** ANCHOR7_L1" "anchor-multiline: 7-line L1"
assert_contains "$out" "ANCHOR7_L2" "anchor-multiline: 7-line L2"
assert_contains "$out" "ANCHOR7_L3" "anchor-multiline: 7-line L3"
assert_contains "$out" "ANCHOR7_L4" "anchor-multiline: 7-line L4"
assert_contains "$out" "ANCHOR7_L5" "anchor-multiline: 7-line L5"
assert_contains "$out" "ANCHOR7_L6" "anchor-multiline: 7-line L6"
assert_contains "$out" "ANCHOR7_L7" "anchor-multiline: 7-line L7"

# 8-line anchor: 3+[…]+3, two middle lines absent.
assert_contains "$out" "**after** ANCHOR8_L1" "anchor-multiline: 8-line L1 (head)"
assert_contains "$out" "ANCHOR8_L2" "anchor-multiline: 8-line L2 (head)"
assert_contains "$out" "ANCHOR8_L3" "anchor-multiline: 8-line L3 (head)"
assert_contains "$out" "ANCHOR8_L6" "anchor-multiline: 8-line L6 (tail)"
assert_contains "$out" "ANCHOR8_L7" "anchor-multiline: 8-line L7 (tail)"
assert_contains "$out" "ANCHOR8_L8" "anchor-multiline: 8-line L8 (tail)"
assert_not_contains "$out" "ANCHOR8_MIDDLE_DROP_4" "anchor-multiline: middle L4 absent"
assert_not_contains "$out" "ANCHOR8_MIDDLE_DROP_5" "anchor-multiline: middle L5 absent"

# [...] appears, and in correct order: L3 < [...] < L6.
l3_line="$(grep -n 'ANCHOR8_L3' "$out" | head -1 | cut -d: -f1)"
ellipsis_line="$(grep -nF '[…]' "$out" | head -1 | cut -d: -f1)"
l6_line="$(grep -n 'ANCHOR8_L6' "$out" | head -1 | cut -d: -f1)"
[[ -n "$l3_line" && -n "$ellipsis_line" && -n "$l6_line" \
    && $l3_line -lt $ellipsis_line && $ellipsis_line -lt $l6_line ]] \
    || fail "anchor-multiline: expected L3 < [...] < L6 order"
```

- [ ] **Step 3: Update existing anchor assertions in the `extract-basic` scenario**

The emit format changes from `**after {text}**` to `**after** {text}`. Update the five assertions in the `extract-basic` block (around line 87–91):

```bash
# before:
assert_contains "$out" "**after (session start)**" "basic: session-start anchor"
assert_contains "$out" "**after Wrote file1**" "basic: text anchor"
assert_contains "$out" "**after Done editing**" "basic: text anchor (image prompt)"
assert_contains "$out" "**after [Bash] echo hi**" "basic: command anchor"
assert_contains "$out" "**after [Edit] /handoff-test/file2.py**" "basic: file_path anchor"

# after:
assert_contains "$out" "**after** (session start)" "basic: session-start anchor"
assert_contains "$out" "**after** Wrote file1" "basic: text anchor"
assert_contains "$out" "**after** Done editing" "basic: text anchor (image prompt)"
assert_contains "$out" "**after** [Bash] echo hi" "basic: command anchor"
assert_contains "$out" "**after** [Edit] /handoff-test/file2.py" "basic: file_path anchor"
```

- [ ] **Step 4: Run tests, confirm red**

```bash
just extract-test
```

Expected: multiple FAILs — new scenario fails (feature not yet implemented) and the five updated basic assertions fail (old format still in code).

---

### Task 2: Implement (green)

**Files:**
- Modify: `scripts/extract.py`

- [ ] **Step 1: Add constants**

Replace the existing `ANCHOR_TEXT_LIMIT = 120` line (keep it — still used for command truncation) and add three new constants directly after it:

```python
ANCHOR_TEXT_LIMIT = 120
ANCHOR_LINE_LIMIT = 7    # show all lines if count <= this; truncation hides ≥2 lines
ANCHOR_HEAD_LINES = 3    # lines shown before [...]
ANCHOR_TAIL_LINES = 3    # lines shown after [...]
```

- [ ] **Step 2: Add `clamp_anchor_lines` helper**

Insert after the `WRAPPER_EXACT` block and before `load_entries`:

```python
def clamp_anchor_lines(lines: list[str]) -> list[str]:
    if len(lines) <= ANCHOR_LINE_LIMIT:
        return lines
    return lines[:ANCHOR_HEAD_LINES] + ["[…]"] + lines[-ANCHOR_TAIL_LINES:]
```

- [ ] **Step 3: Modify `anchor_for` text branch**

Current code (inside the `if btype == "text":` block, around line 169):

```python
            if btype == "text":
                text = (block.get("text") or "").strip()
                if text:
                    return text.splitlines()[0][:ANCHOR_TEXT_LIMIT]
```

Replace with:

```python
            if btype == "text":
                text = (block.get("text") or "").strip()
                if text:
                    return "\n".join(clamp_anchor_lines(text.splitlines()))
```

- [ ] **Step 4: Modify `emit` anchor rendering**

Current code (inside the `if tail_prompts:` loop, around line 216):

```python
        lines.append(f"**after {anchor}**")
        lines.append("")
        lines.extend(format_quote(text))
        lines.append("")
```

Replace with:

```python
        anchor_lines = anchor.splitlines()
        lines.append(f"**after** {anchor_lines[0]}")
        for al in anchor_lines[1:]:
            lines.append(al)
        lines.append("")
        lines.extend(format_quote(text))
        lines.append("")
```

- [ ] **Step 5: Run tests, confirm green**

```bash
just extract-test
```

Expected: `all extract scenarios passed`

---

### Task 3: Full precommit and commit

**Files:** none new

- [ ] **Step 1: Run full precommit**

```bash
just precommit
```

Expected: all checks pass (manifest lint, script syntax, hook tests, extract tests, rename tests).

- [ ] **Step 2: Commit**

```bash
git add scripts/extract.py tests/fixtures/anchor-multiline.jsonl tests/extract-test.sh
git commit -m "feat: show multi-line assistant anchor text (3+[…]+3 at ≥8 lines)"
```

---

## Self-review

**Spec coverage:**
- ✅ ≤7-line text shows in full (ANCHOR_LINE_LIMIT=7; truncation always hides ≥2 lines)
- ✅ ≥8-line text: first 3 + `[…]` + last 3
- ✅ 120-char truncation removed from text branch (`ANCHOR_TEXT_LIMIT` retained for command path)
- ✅ Anchor stays inline (not blockquote)
- ✅ Tool-use anchors (single-line) unaffected — `anchor.splitlines()` on a one-liner returns a one-element list, loop body never executes
- ✅ Fixture + assertions per spec
- ✅ Existing fixture tests updated for new `**after** text` format

**Placeholder scan:** none found.

**Type consistency:** `clamp_anchor_lines` takes and returns `list[str]`; called with `text.splitlines()` (returns `list[str]`); result passed to `"\n".join(...)` which returns `str` — consistent with `anchor_for` return type `str` throughout.
