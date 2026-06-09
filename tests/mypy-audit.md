# mypy / typing audit — `scripts/*.py`, `tests/*.py`

**Verdict:** largely compliant — an already-strict, already-passing
codebase with zero suppression debt; the only substantive tightenings are
optional config hygiene (a deprecated-alias rename + two now-redundant
lines, all live because the *installed* mypy is 2.1.0) and one
maintainability nit (a tool-name magic string duplicated with inconsistent
ordering).

## Ground truth (tools run 2026-06-09)

| Tool | Version | Result |
|------|---------|--------|
| `mypy` (project config) | 2.1.0 | clean |
| `ty check` | 0.0.46 | clean |
| `ruff check scripts tests` | 0.15.16 | clean |

Additional probes:

- `mypy --strict --warn-unreachable scripts tests` → **clean** (no dead
  branches; `warn_unreachable` could be turned on at zero cost).
- `mypy --strict --disallow-any-explicit scripts tests` → **one finding**,
  `extract.py:43` (`Entry = dict[str, Any]`) — the single deliberate,
  guideline-sanctioned boundary `Any`.
- `grep` for `cast(`, `# type: ignore`, `reveal_type`, `# noqa` across
  `scripts/` and `tests/` → **zero hits**. No suppression debt exists to
  audit.

The installed mypy is **2.1.0**, not the `mypy>=1.19.1` floor. The
guidelines gate two config calls on "once the floor moves to ≥ 2.0"; since
the resolved interpreter is already 2.x, the deprecated-alias and
redundant-default observations are live, not hypothetical — see Config.

---

## Findings by severity

### High

None. No correctness defect, no suppression, no untyped def, no bare
generic, no `warn_return_any` leak (the JSON-parse functions either return
`Entry`/`list[Entry]` by constructing the list locally or narrow before
returning a concrete `str`/`bool`). An empty high section is the honest
outcome here.

### Medium

None.

### Low

**L1 — `"Write"`/`"Edit"` magic strings duplicated with inconsistent
ordering.**
*Location:* `scripts/extract.py:87` (`not in ("Write", "Edit")`) and
`scripts/extract.py:141` (`not in ("Edit", "Write")`).
*Guideline:* "Prefer structured types over primitives →
`Literal[...]`/`Enum` for a fixed set of string constants … **AVOID raw
magic-string comparisons like `name not in ("Write", "Edit")` scattered
across a module — hoist to a `Literal`/`Enum` or at least a named constant
so a rename is one edit and a typo is a type error.**" The guideline names
this file and these exact strings.
*Issue:* the same closed two-element tool-name set is spelled inline in two
functions, and the tuples are even ordered differently (`("Write","Edit")`
vs `("Edit","Write")`) — cosmetic today, but exactly the drift the rule
warns about; a future rename touches two sites and a typo (`"Wrtie"`) is
silently accepted because the surrounding `block` is `Any`.
*Recommendation:* hoist a module-level named constant, e.g.
`TOUCH_TOOLS = ("Edit", "Write")` (or a `frozenset`), and use it in both
membership tests. This is the *lightest* fix and the one the guideline
explicitly offers as the floor ("or at least a named constant"). It removes
the duplication and the ordering inconsistency without adding any type
machinery. See the **Literal/Enum tradeoff** note below for why the
heavier option does not pay here.

### Nit

**N1 — `block.get("name", "tool")` and `block.get("type")` read a
known-but-open block shape as `Any`.**
*Location:* `scripts/extract.py` throughout `tool_use_blocks`,
`_is_handoff_write`, `extract_files_touched`, `anchor_for`, `user_text`
(e.g. lines 80, 87, 143, 164, 204).
*Guideline:* "DO type JSON-shaped data at the boundary … For dicts with a
known, fixed key set use a `TypedDict`" vs. "WHEN the JSON shape is
open/unknown … a bare `dict[str, Any]` … is the honest annotation."
*Issue:* the content-block accesses (`type`, `name`, `input`, `text`) have
a *fairly* known shape, so in principle a `TypedDict(total=False)` for a
content block would let mypy catch a misspelled key. But the access is
guarded throughout by `isinstance(block, dict)` + `.get(...)` with
defaults, and the block values themselves stay `Any` (the transcript format
"evolves" per CLAUDE.md). A `TypedDict` would check the *key spelling* but
not the *value types* (they would still be `Any`), and would force either a
narrowing/parse step or a `cast` at the `for block in content` boundary —
the latter is exactly what the guidelines say to avoid.
*Recommendation:* **leave as-is.** This is a nit, not a defect: the code
sits on the open-shape side of the guideline's own dividing line for an
undocumented, evolving format, and the marginal key-spell checking a
`TypedDict` buys does not justify the parse/`cast` boundary it would
introduce. Recorded only so a future reader knows it was considered.

---

## Literal/Enum tradeoff (the question the brief asked to weigh)

Would `Literal["Write", "Edit"]` actually help, given the surrounding dict
stays `Any`? **Mostly no, for `extract.py` specifically.** Each access is
`block.get("name")` where `block: Entry` (i.e. `dict[str, Any]`), so the
result is `Any` — mypy will *not* check an `Any` against a `Literal`, so a
`Literal` annotation on a local would be erased the moment it touches the
dict. To get real checking you would have to first narrow
(`name = block.get("name"); assert isinstance(name, str)`) and compare
against an `Enum`/`Literal`, which is more ceremony than this five-line
function warrants.

So the **payoff of the heavy options (Enum/Literal) is near-zero here**,
precisely *because* the boundary dict is `Any` — and that `Any` is itself
sanctioned. The **value that does survive** is the de-duplication and
typo-resistance of a **named constant** (L1): one definition, one rename
site, and a typo in the *constant's* value is at least a single obvious
place to look. That is the right altitude for this codebase. The scattered
single-use strings (`"tool_use"`, `"text"`, `"tool_result"`, `"assistant"`,
`"user"`) each appear in one logical place tied to one structural check;
hoisting them to constants/enums would add naming overhead without removing
duplication or enabling checking (same `Any`-boundary reason). Leave them
inline.

`worktree_root.py` has no magic-string constant sets — its string literals
(`"gitdir:"`, `os.sep`) are protocol tokens used once, correctly inline.

---

## Config recommendations

All three apply to the **installed mypy 2.1.0**. The guidelines defer two of
them to "once the floor is ≥ 2.0"; since the interpreter resolving the
config is already 2.x, they are actionable now (subject to the team's call
on whether to also raise the `mypy>=` floor — see note).

- **`allow_redefinition_new = true` → `allow_redefinition = true`
  (recommend the rename).** On mypy 2.x `allow_redefinition_new` is a
  *deprecated alias* (guidelines §Config hygiene, §Repo notes; verified in
  the doc's review log against `config_file.html`). Functionally identical
  today, but it is a deprecated key the installed mypy will eventually drop.
  *Caveat:* the `pyproject.toml` `mypy>=1.19.1` floor still permits
  installing a 1.x mypy where the new key is the *only* spelling — so the
  clean migration is to **bump the floor to `mypy>=2.0` in the same change**
  as the rename. If the team wants to keep the 1.19 floor for some reason,
  leave the key as-is (it is correct under 1.x); do not split the two.

- **`extra_checks = true` — redundant, safe to drop.** It is already inside
  the `--strict` bundle (guidelines §Strict mode, confirmed in the review
  log). Harmless but noise. Optional removal for clarity.

- **`local_partial_types = true` — redundant default on mypy ≥ 2.0, safe to
  drop *if* the floor moves to 2.0.** Default `True` since mypy 2.0
  (guidelines §Config hygiene). With the floor still at 1.19.1 the explicit
  line documents intent and guards the 1.x default; keep it until the floor
  is raised, then it may be dropped. (Note: the new-redefinition behavior
  *requires* `local_partial_types`, so never set `no_local_partial_types`.)

Config items the doc raises that are **not** in this `pyproject.toml`,
with a one-line should-we for *this* codebase:

- **`warn_unreachable = true` — yes, low-value-but-free.** Probed clean
  above, so adding it costs nothing today and catches dead branches left by
  future over-narrow annotations. The guidelines' "Repo notes" already flag
  it as the one worth-considering addition. Recommended.
- **`strict_bytes` — N/A.** Default-on since mypy 2.0 (the installed
  version), and neither script does `bytes`/`bytearray`/`memoryview` mixing
  (`extract.py` reads text with `encoding=...`). Nothing to enable, nothing
  at risk.
- **`disallow_any_explicit` — no.** It would flag exactly one line,
  `Entry = dict[str, Any]` (confirmed by probe), which is the guidelines'
  canonical *sanctioned* boundary `Any` for the undocumented, evolving
  transcript format. The guidelines say so directly: "For JSON-parsing code
  (this repo) it is usually too blunt; prefer typing the boundary over a
  global ban." Do not enable.
- **Optional error codes (`redundant-expr`, `truthy-bool`,
  `possibly-undefined`, `explicit-override`) — optional, low priority.**
  None would fire on the current code (no class hierarchies for
  `explicit-override`; no always-true/false exprs; control flow is simple).
  `possibly-undefined` is the only one with any future value as the scripts
  grow; enabling it is cheap but not pressing.
- **`disable_error_code` / per-module loosening overrides — keep absent.**
  The config has none; the guidelines call this clean. Do not add any.

`[tool.ruff]` and `[tool.ty]` are consistent with the guidelines: `ALL`
select with a documented, defensible `ignore` list; `TC001`–`TC003`
deliberately ignored (guidelines bless this for small scripts); ty wired as
a preview parity probe under `[tool.ty]`, not as the gate — "exactly the
recommended posture." The three path settings (mypy `mypy_path`, pytest
`pythonpath`, ty `extra-paths`) all point at `scripts/` and are in sync, as
the guidelines require.

---

## Compliant / deliberate choices (not defects) — credit where due

- **`Entry = dict[str, Any]` (extract.py:43)** — the textbook
  honest-boundary annotation the guidelines hold up as the *right* call for
  an undocumented, evolving format. Parameterised (satisfies
  `disallow_any_generics`), commented (line 42 reads as intentional), and
  narrowed at each field read. **The single most important thing the code
  gets right.**
- **Zero `cast`, zero `# type: ignore`, zero `reveal_type`, zero `# noqa`**
  — no suppression debt anywhere. The guidelines' entire "Avoiding
  suppression debt" section has nothing to flag.
- **All test functions annotated `-> None`**, all helpers fully typed
  (`render_frame(... ) -> str`, `assert_order(...) -> None`, etc.) —
  satisfies `disallow_untyped_defs` under strict with room to spare; the
  guidelines call this out as a thing to keep.
- **Fully-parameterised generics throughout** (`list[Entry]`,
  `list[tuple[int, str]]`, `dict[str, Any]`, `list[str]`) — no bare
  `list`/`dict`/`tuple` that `disallow_any_generics` would catch.
- **Explicit Optional** — `transcript_path: Path | None` in the test helper;
  no implicit-`None`-default annotations anywhere
  (`no_implicit_optional`-clean).
- **Narrowing via `isinstance`, never `cast`** — `tool_use_blocks`,
  `user_text`, `anchor_for` all guard with `isinstance(block, dict)` /
  `isinstance(content, str | list)` before structural access, exactly the
  "narrow, don't cast" rule.
- **No `warn_return_any` leak from the JSON path** — functions that touch
  `json.loads(...)` build a local `list[Entry]` and return that, or narrow
  to a concrete `str`/`bool` before returning, so the strict
  `warn_return_any` member never trips.
- **`worktree_root.py`'s deliberate `os.path` string work** is documented
  in `pyproject.toml` per-file ruff ignores with the reason (relative
  `gitdir:` must stay un-normalized) — a sanctioned, commented deviation,
  not a lint hole.
- **stdlib-only, no pydantic** — correct per the guidelines' explicit note
  that pydantic is "the heaviest option and likely overkill" for a
  stdlib-only hook script with no runtime deps by design.
