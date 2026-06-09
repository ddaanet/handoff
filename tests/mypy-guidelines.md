# mypy guidelines — review checklist

Engineering-grade rules for type-checking this repo's Python with mypy
(plus ruff and ty). Phrased as checkable DO/AVOID rules so a later agent
can audit `scripts/*.py` and `tests/*.py` against them. Each non-obvious
claim cites a primary source inline.

Verified against mypy **2.1.0** stable (the installed floor is
`mypy>=1.19.1`, but current stable is 2.1.0 and mypy **2.0** changed two
defaults that matter here — see [Repo notes](#repo-notes)). Sources are
listed at the bottom; URLs are also inlined at each claim.

## Strict mode

`--strict` is a bundle, not a single check. As of mypy 2.1 it enables:
`--disallow-any-generics`, `--disallow-subclassing-any`,
`--disallow-untyped-calls`, `--disallow-untyped-defs`,
`--disallow-incomplete-defs`, `--check-untyped-defs`,
`--disallow-untyped-decorators`, `--warn-redundant-casts`,
`--warn-unused-ignores`, `--warn-return-any`, `--no-implicit-reexport`,
`--strict-equality`, and `--extra-checks`
([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
The exact set grows across releases, so pin the mypy version if you depend
on the bundle's contents. mypy **2.0** also made `--strict-bytes` a
default (independent of `--strict`): `bytearray`/`memoryview` are no longer
implicitly assignable to `bytes` (PEP 688)
([mypy 2.0 release](https://mypy-lang.blogspot.com/2026/05/mypy-20-relased.html)).

A few bundle members are worth calling out as *checkable rules* in their
own right, since an audit pass should know what they catch:

- **`disallow_any_generics`** — "disallows usage of generic types that do
  not specify explicit type parameters"
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
  This is the rule that forces `dict[str, Any]` instead of a bare `dict`,
  and is exactly why this repo spells its JSON-entry alias as
  `Entry = dict[str, Any]` (see `scripts/extract.py`) rather than
  `Entry = dict`. **DO write fully-parameterised generics** (`list[str]`,
  `dict[str, Any]`, `Sequence[int]`); a bare `list`/`dict`/`tuple` in an
  annotation is a finding under strict.
- **`strict_equality`** — "prohibit[s] [...] comparisons of non-overlapping
  types" so `42 == "no"` (always-false) is an error
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
  **DO treat a `strict-equality` finding as a real bug** (mismatched
  operands), not noise to suppress.
- **`warn_return_any`** — warns "when returning a value with type `Any`
  from a function declared with a non-`Any` return type"
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
  This is the strict member that bites JSON-parsing code: `json.loads(...)`
  is `Any`, so returning it from a `-> Entry` function trips the warning.
  **DO narrow (or annotate the intermediate)** rather than suppress.
- **`no_implicit_optional` is on by default** (since mypy 0.980, not a
  strict member): a `None` default no longer implies `T | None`
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
  **DO write the Optional explicitly** — `def f(x: str | None = None)`,
  never `def f(x: str = None)`.

Configuration and opt-in rules around the bundle:

- **DO set `strict = true`.** It is the floor, not the ceiling. With it,
  "you will basically never get a type related error at runtime without a
  corresponding mypy error, unless you explicitly circumvent mypy"
  ([getting_started.html](https://mypy.readthedocs.io/en/stable/getting_started.html)).
- **DO add `warn_unreachable`** on top of strict — it is NOT in the
  bundle. It "report[s] an error whenever it encounters code determined to
  be unreachable or redundant after performing type analysis"
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)),
  which surfaces dead branches left by over-narrow annotations. Caveat: it
  reasons over types, not values, so it can't see value-level dead code,
  and `if TYPE_CHECKING`/version guards can trip it — suppress those
  narrowly, don't disable the flag
  ([Adam Johnson](https://adamj.eu/tech/2021/05/19/python-type-hints-mypy-unreachable-code-detection/)).
- **CONSIDER `disallow_any_explicit`** — it "disallows explicit `Any` in
  type positions such as type annotations and generic type parameters"
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
  Tradeoff: it bans the deliberate `Any` escape hatch entirely, so it only
  pays off in code with no genuinely-dynamic boundary. For JSON-parsing
  code (this repo) it is usually too blunt; prefer typing the boundary
  (below) over a global ban.
- **CONSIDER opt-in optional codes** beyond strict, each via
  `enable_error_code`: `redundant-expr` (always-true/false expressions),
  `truthy-bool` (objects without `__bool__`/`__len__` in a boolean
  context), `possibly-undefined` (var maybe-unset on some path),
  `explicit-override` (require `@override`). All are off by default and
  must be enabled explicitly
  ([error_code_list2.html](https://mypy.readthedocs.io/en/stable/error_code_list2.html)).
- **`extra_checks`** is already inside `--strict`; setting it again is
  harmless but redundant. It "enables additional checks that are
  technically correct but may be impractical," e.g. prohibiting partial
  overlap in `TypedDict` updates
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).

## Config hygiene

- **DO use `files`/`mypy_path`** for a flat-module layout (no package, no
  `__init__.py`). `mypy_path` "specifies the paths to use, after trying
  the paths from MYPYPATH" and "may only be set in the global section"
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
  This is how `scripts/` modules (`extract`, `worktree_root`) resolve
  without a package prefix — mirroring pytest's `pythonpath`. Use
  `packages =` only for real importable packages with `__init__.py`.
- **AVOID per-module `[[tool.mypy.overrides]]` that loosen strictness**
  unless the relaxation is forced by a third party you don't control.
  A self-authored module that needs `disallow_untyped_defs = false` is a
  code smell — fix the annotations instead. Override precedence is
  inline > per-module > global
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)),
  so an override silently masks the global strict setting; keep them
  greppable and commented with the reason.
- **AVOID `disable_error_code` at config level** for anything but a
  documented, whole-codebase exemption. Disabling a code globally hides
  every future instance, including new bugs. Prefer a line-level
  `# type: ignore[code]` so the suppression is local and visible
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
- **KNOW that `exclude` only affects recursive *discovery*, not paths
  given explicitly.** Per the docs, `exclude` is "A regular expression that
  matches file names, directory names and paths which mypy should ignore
  while recursively discovering files to check"
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html));
  a file passed on the command line, or pulled in via `files`/import
  resolution, is still checked even if it matches `exclude` (mypy
  [#11760](https://github.com/python/mypy/issues/11760)). Audit rule: if a
  file you expected to be skipped is still type-checked, it's reachable via
  `files`/`mypy_path` — narrow `files` rather than expecting `exclude` to
  override it. (`force_exclude` exists for the discovery case but is not
  needed in this repo's explicit `files = ["scripts","tests"]` setup.)
- **For gradual adoption** (introducing strict mypy into an untyped
  codebase), don't flip `strict = true` globally on day one. Start with the
  default (lenient) config, then ratchet: enable one strict sub-flag at a
  time, or scope strictness to already-clean modules via a per-module
  override that *raises* strictness (the inverse of the loosening overrides
  warned against above), then widen
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
  This repo is already fully strict and small, so this is N/A here — listed
  for when the same checklist is reused on a larger codebase.
- **`local_partial_types`** prevents inferring a variable's type from an
  empty container that is later filled in another scope, and "must be
  enabled when using the mypy daemon"
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
  As of **mypy 2.0 it is enabled by default**; explicitly disabling it is
  still supported "for now" but "this support will be removed in the
  future"
  ([mypy 2.0 release](https://mypy-lang.blogspot.com/2026/05/mypy-20-relased.html)).
  DO keep it on (or rely on the default); never set `no_local_partial_types`.
- **`allow_redefinition_new`** was the mypy 1.16–1.20 experimental name
  for flexible redefinition (redefine a variable at a different type;
  infer a union from multiple assignments)
  ([changelog](https://mypy.readthedocs.io/en/stable/changelog.html)). In
  **mypy 2.0 the plain `--allow-redefinition` adopted that behavior**, the
  old behavior moved to `--allow-redefinition-old`, and on 2.x docs
  `allow_redefinition_new` is now a **deprecated alias**
  ([mypy 2.0 release](https://mypy-lang.blogspot.com/2026/05/mypy-20-relased.html),
  [config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
  The new behavior requires `local_partial_types`. **DO migrate the config
  key to `allow_redefinition = true`** once on mypy ≥ 2.0.

## Annotation practices

- **DO type JSON-shaped data at the boundary, not with bare
  `dict[str, Any]` everywhere.** For dicts with a known, fixed key set use
  a `TypedDict`: unlike `dict[str, Any]` it lets the checker catch
  undefined-key access and wrong value types at dev time
  ([typing spec: TypedDict](https://typing.python.org/en/latest/spec/typeddict.html)).
  Use `total=False` (all keys optional) or per-key `NotRequired[...]` for
  partially-present payloads. Note TypedDict values must be a real `dict`,
  not a subclass.
- **WHEN the JSON shape is open/unknown** (arbitrary keys, untrusted
  external transcript format that "evolves"), a bare `dict[str, Any]` or a
  type alias at the parse boundary is the honest annotation — `Any` here is
  a real boundary, not a hole. This repo does exactly this with
  `Entry = dict[str, Any]` in `scripts/extract.py`: it parameterises the
  generic (satisfying `disallow_any_generics`) while owning the `Any` as a
  deliberate, documented boundary for the undocumented transcript format.
  Narrow to concrete types as soon as you read a field. **DO comment the
  alias** so the `Any` reads as intentional, not lazy.

### Prefer structured types over primitives

Bare `dict[str, Any]` and bare string constants are the two places a
strict checker goes blind. Reach for a structured type before a primitive;
pick the lightest one that buys real checking. The gradient, lightest to
heaviest:

- **`Literal[...]` / `Enum` for a fixed set of string (or int) constants.**
  When a field has a closed value set — e.g. a tool name `"Write" | "Edit"`,
  a block `type` of `"tool_use" | "text" | "tool_result"` — annotate it as
  `Literal["Write", "Edit"]` (or an `enum.Enum`) instead of `str`. The
  checker then catches a typo'd or stale comparison (`block["name"] ==
  "Wrtie"`) and exhaustiveness gaps that a bare `str` waves through; mypy
  has dedicated Literal and Enum narrowing
  ([literal_types.html](https://mypy.readthedocs.io/en/stable/literal_types.html)).
  Prefer `Literal` for ad-hoc closed sets, `Enum` when the set has a name,
  members worth referencing, or behavior. **AVOID raw magic-string
  comparisons** like `name not in ("Write", "Edit")` scattered across a
  module — hoist to a `Literal`/`Enum` or at least a named constant so a
  rename is one edit and a typo is a type error. This repo's `extract.py`
  does exactly the scattered-magic-string thing (`"Write"`, `"Edit"`,
  `"tool_use"`, `"text"`, `"tool_result"`, `"assistant"`, `"user"`) — the
  audit should weigh whether a `Literal`/`Enum` is worth it given the dicts
  themselves stay `Any` at the boundary.
- **`TypedDict` for a JSON object with a known, fixed key set** (see the
  bullet above) — the apt, zero-runtime structural fit for decoded JSON.
  It models "a `dict` with these keys/value-types" without a parse step, so
  it's the natural upgrade from `dict[str, Any]` when the shape is known.
- **`@dataclass` (or `NamedTuple`) when you construct/parse into objects**
  rather than passing dicts around. A dataclass implies a parse boundary
  (`Entry(**d)` or a `from_json`); in return mypy checks attribute access,
  `__init__` signatures, and (frozen) immutability
  ([additional_features.html](https://mypy.readthedocs.io/en/stable/additional_features.html#dataclasses)).
  Choose this over TypedDict when you want methods, defaults, or identity —
  not merely structural dict access.
- **pydantic when you need runtime validation at a boundary** (untrusted
  input, config, API payloads). It's the strongest — it *enforces* the
  types at runtime, and its mypy plugin tightens model signatures
  ([pydantic mypy plugin](https://docs.pydantic.dev/latest/integrations/mypy/)).
  But it is a **third-party runtime dependency**. Weigh that against the
  context: in an application, often worth it; in a stdlib-only hook script
  like `extract.py` (no runtime deps by design), it's the heaviest option
  and likely overkill — a `TypedDict` + narrowing carries no dependency.

The rule of thumb: **`Literal`/`Enum` for constants, `TypedDict` for known
JSON shapes, `dataclass` when you parse, pydantic when you must validate.**
Default toward the lightest that removes the `Any`/magic-string blind spot.

- **PREFER `object` over `Any` when you accept anything but won't operate
  on it blindly.** `object` "only supports operations defined for _all_
  objects, such as equality and isinstance()"; `Any` "supports all
  operations, even if they may fail at runtime"
  ([common_issues.html](https://mypy.readthedocs.io/en/stable/common_issues.html)).
  `object` forces a narrowing step; `Any` silently disables checking.
- **DO narrow with `isinstance` / `assert isinstance`** rather than
  `cast`. Mypy infers types after an `isinstance` check, and "you can use
  an `assert` statement together with [...] type inference techniques" to
  narrow (`assert isinstance(found, str)`)
  ([common_issues.html](https://mypy.readthedocs.io/en/stable/common_issues.html)).
  An `assert` also fails loudly at runtime if the invariant breaks; a
  `cast` does not.
- **AVOID `cast` except where narrowing genuinely cannot reach.** `cast`
  bypasses type safety with zero runtime check — mypy trusts it blindly
  ([common_issues.html](https://mypy.readthedocs.io/en/stable/common_issues.html)).
  With `warn_redundant_casts` (in `--strict`) mypy will at least flag a
  cast that does nothing. Every `cast` deserves a comment justifying why
  narrowing was impossible.
- **DO annotate test functions `-> None`.** Under `--strict`,
  `disallow_untyped_defs` requires it; an un-annotated `def test_x():` is
  an untyped def and mypy will flag it. This repo's tests are already
  fully annotated — keep them that way.
- **DON'T let an untyped decorator erase a function's signature.**
  `disallow_untyped_decorators` (in `--strict`) flags decorating a typed
  function with an untyped decorator
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)),
  because an untyped decorator makes the decorated function `Any`,
  silently dropping its annotations. For pytest, `@pytest.fixture` and
  `@pytest.mark.*` are typed in modern `pytest` (≥8, this repo's floor), so
  this should not fire; if it does, the fix is a properly-typed decorator,
  not a per-line ignore.
- **USE `reveal_type(expr)` to debug inference, then delete it.** mypy
  prints the static type of `expr` at that point (no import needed at
  type-check time)
  ([common_issues.html](https://mypy.readthedocs.io/en/stable/common_issues.html)).
  It's the fastest way to see why a narrowing didn't take. Enable the
  optional `unimported-reveal` code if you want mypy to *require* importing
  `reveal_type`, so a stray debug call can't ship
  ([error_code_list2.html](https://mypy.readthedocs.io/en/stable/error_code_list2.html)).

## Avoiding suppression debt

- **DO write `# type: ignore[code]` with the specific error code, never a
  bare `# type: ignore`.** The coded form "only ignore[s] specific errors
  on the line," which "prevents accidentally silencing unexpected errors
  and documents the purpose"
  ([common_issues.html](https://mypy.readthedocs.io/en/stable/common_issues.html)).
  Bare ignores mask future, unrelated errors on that line.
- **DO let `warn_unused_ignores` (in `--strict`) garbage-collect stale
  ignores.** It "report[s] an error whenever your code uses a
  `# type: ignore` comment on a line that is not actually generating an
  error"
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)),
  so suppressions can't outlive the bug they hid. (Enforce
  `ignore-without-code` if you want bare ignores to be a hard error.)
- **PREFER `assert` for narrowing over an ignore.** An ignore hides the
  signal; an `assert` proves the invariant and narrows the type
  ([common_issues.html](https://mypy.readthedocs.io/en/stable/common_issues.html)).

## mypy + ruff: division of labor

Astral's own guidance: "use Ruff in conjunction with a type checker, like
Mypy [...] with Ruff providing faster feedback on lint violations and the
type checker providing more detailed feedback on type errors"
([ruff FAQ](https://docs.astral.sh/ruff/faq/)).

- **Ruff owns annotation *presence*** via the `ANN` group
  (flake8-annotations), which lints for missing annotations on function
  defs/args/returns. With `select = ["ALL"]` this repo gets `ANN` for
  free. This **overlaps the intent of** `disallow_untyped_defs` in
  `--strict`: both want the annotation present. The overlap is benign,
  but the tools are not identical — ruff lints *presence* (a missing
  annotation), mypy checks *correctness* (the annotation is sound). A
  missing-annotation finding may surface from either; a wrong-annotation
  finding only from mypy. (The ruff FAQ recommends pairing the two but
  does not equate `ANN` with `disallow_untyped_defs`
  — [ruff FAQ](https://docs.astral.sh/ruff/faq/).)
- **Ruff owns import placement** via `TC`/`TCH` (flake8-type-checking):
  `TC001`/`TC002`/`TC003` flag first-party/third-party/stdlib imports used
  only in annotations, suggesting an `if TYPE_CHECKING:` block to cut
  runtime overhead
  ([TC001](https://docs.astral.sh/ruff/rules/typing-only-first-party-import/)).
  This repo **deliberately ignores `TC001`–`TC003`** (see `pyproject.toml`)
  — a defensible choice for small scripts where the runtime-import cost is
  negligible and `TYPE_CHECKING` blocks add noise. Don't re-enable without
  reason.
- **mypy owns type *correctness*** — narrowing, return-type soundness,
  generics, overload resolution. Ruff does not type-check. Keep
  type-semantics rules in mypy and lint-shape rules in ruff; don't try to
  reproduce mypy checks with ruff or vice versa.

## mypy vs ty (Astral)

ty is Astral's Rust type checker — "10x - 100x faster than mypy and
Pyright" ([ty docs](https://docs.astral.sh/ty/)) — but it is **beta**:
"Today, we're announcing the Beta release of ty [...] we're working
towards a Stable release next year" ([ty blog](https://astral.sh/blog/ty),
posted 2025; "next year" = 2026). The blog does not mention strict mode;
the absence of a strict bundle is established below from ty's own rules
reference, not the blog. Treat ty as a complementary second opinion, not a
mypy replacement:

- **No strict-mode parity.** ty has configurable rule *levels*
  (`error`/`warn`/`ignore`) but no `--strict` bundle equivalent and no
  rule that requires annotations on every function
  ([ty rules](https://docs.astral.sh/ty/reference/rules/)). So it cannot
  enforce this repo's strictness contract — mypy remains the gate.
- **Different defaults and narrowing.** ty checks all code by default
  (including untyped), and its design centers the "gradual guarantee":
  adding annotations to working code never introduces new errors
  ([ty docs](https://docs.astral.sh/ty/)). Its narrowing and reachability
  analysis differ from mypy's, so the two can legitimately disagree — a ty
  finding is a prompt to investigate, not an automatic mypy bug.
- **No plugin system** (and no plans for one), so ty can't replace mypy
  where ORM/Pydantic plugins matter
  ([ty github](https://github.com/astral-sh/ty)). Not relevant to this
  plugin-free repo, but relevant before adopting ty anywhere.
- **Suppression syntax differs.** ty understands standard
  `# type: ignore`, plus its own `# ty: ignore[code]` and
  `# type: ignore[ty:code]`
  ([ty rules](https://docs.astral.sh/ty/reference/rules/)). A code that
  matches no known rule suppresses nothing.
- **DO run ty as a parity probe** alongside mypy (as this repo already
  wires it under `[tool.ty]`): green-on-both raises confidence; a
  divergence is a signal to read both tools' reasoning. **DON'T** gate CI
  on ty alone or drop mypy for it yet.

## Practical gotchas

- **Third-party stubs.** For libraries shipping no inline types, install
  the `types-*` stub package (e.g. `types-requests`); mypy emits
  `import-untyped` / `no-any-unimported` otherwise. This repo's runtime
  deps are stdlib-only, so no stubs are needed — but don't paper over a
  future missing stub with a module-level `ignore_missing_imports`
  override when a `types-*` package exists.
- **Flat modules vs namespace packages.** With no `__init__.py` (this
  repo's `scripts/` and `tests/`), mypy resolves imports via `mypy_path`,
  pytest via `pythonpath` + `--import-mode=importlib`. `namespace_packages`
  defaults to `True` (PEP 420)
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
  Keep the three path settings (mypy `mypy_path`, pytest `pythonpath`, ty
  `extra-paths`) in sync — they all point at `scripts/`; drift breaks one
  tool silently. Avoid same-named modules in two unpackaged dirs:
  importlib mode can't disambiguate them.
- **`warn_redundant_casts`** (in `--strict`) flags casts that change
  nothing; treat its findings as "delete the cast," not "add an ignore."
- **`no_implicit_reexport`** (in `--strict`) means a name imported into a
  module is NOT re-exported unless imported via `from ... import x as x`
  or listed in `__all__`
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
  If a test imports a helper that another module merely re-imported,
  expect an `attr-defined` error — fix the source module's `__all__`,
  don't suppress.

## Repo notes

What this config already does well, and the one deliberate-vs-stale call:

- **`strict = true`** — correct floor. ✓
- **`extra_checks = true`** — already implied by strict; harmless but
  redundant. Could drop the line.
- **`local_partial_types = true`** — required for flexible redefinition;
  on **mypy ≥ 2.0 it is the default**, so the explicit line is now
  redundant (keep it for clarity/back-compat with the 1.19 floor, or drop
  it once the floor is ≥ 2.0).
- **`allow_redefinition_new = true`** — this is the mypy 1.x experimental
  name. On **mypy 2.0+ it is a deprecated alias for `allow_redefinition`**.
  **Action:** once the `mypy>=` floor moves to ≥ 2.0, rename to
  `allow_redefinition = true`. While the floor stays at 1.19.1, the
  current key is correct.
- **`mypy_path = "scripts"` + `files = ["scripts","tests"]`** — correct
  flat-module wiring; mirrors pytest `pythonpath` and ty `extra-paths`. ✓
- **No per-module overrides, no `disable_error_code`** — clean; no
  suppression debt at config level. ✓ Keep it that way.
- **ty wired as a preview parity probe** under `[tool.ty]`, not as the
  gate — exactly the recommended posture. ✓
- **Missing-but-worth-considering:** `warn_unreachable = true` (not in
  strict) would catch dead branches; low cost on a small codebase.

## Sources

- [mypy command line](https://mypy.readthedocs.io/en/stable/command_line.html)
- [mypy config file](https://mypy.readthedocs.io/en/stable/config_file.html)
- [mypy getting started](https://mypy.readthedocs.io/en/stable/getting_started.html)
- [mypy optional error codes](https://mypy.readthedocs.io/en/stable/error_code_list2.html)
- [mypy common issues](https://mypy.readthedocs.io/en/stable/common_issues.html)
- [mypy changelog](https://mypy.readthedocs.io/en/stable/changelog.html)
- [mypy 2.0 release blog](https://mypy-lang.blogspot.com/2026/05/mypy-20-relased.html)
- [mypy #11760 — exclude vs explicit files](https://github.com/python/mypy/issues/11760)
- [typing spec: TypedDict](https://typing.python.org/en/latest/spec/typeddict.html)
- [ruff FAQ](https://docs.astral.sh/ruff/faq/)
- [ruff TC001](https://docs.astral.sh/ruff/rules/typing-only-first-party-import/)
- [ty docs](https://docs.astral.sh/ty/)
- [ty rules reference](https://docs.astral.sh/ty/reference/rules/)
- [ty launch blog](https://astral.sh/blog/ty)
- [ty github](https://github.com/astral-sh/ty)
- [Adam Johnson — unreachable code detection](https://adamj.eu/tech/2021/05/19/python-type-hints-mypy-unreachable-code-detection/)

## Review log

Independent re-research (2026-06-09) against primary sources. The first
agent's draft was **largely accurate** — the high-risk mypy-versioning
claims all held up. Findings:

### Verified correct (re-checked against primary sources)
- **`--strict` bundle contents** (all 13 flags, including `--extra-checks`,
  `--strict-equality`, `--no-implicit-reexport`): matches
  [command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)
  exactly.
- **`extra_checks` is inside `--strict`**: confirmed (so the repo's explicit
  `extra_checks = true` is genuinely redundant — the doc's "Repo notes"
  call is right).
- **`local_partial_types` default `True` as of mypy 2.0**: confirmed,
  [config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)
  ("Default: `True`") and the
  [2.0 blog](https://mypy-lang.blogspot.com/2026/05/mypy-20-relased.html).
- **`allow_redefinition_new` is a deprecated alias for `allow_redefinition`**
  in mypy 2.x: confirmed verbatim in config_file.html ("Deprecated alias
  for allow_redefinition"). The 2.0 behavior change (plain
  `--allow-redefinition` adopting the new semantics, old behavior moved to
  `--allow-redefinition-old`) is confirmed in the changelog/blog — not just
  the blog.
- **mypy 2.0/2.1 actually exist** (current stable 2.1.0); the 2026-05 blog
  URL is real. The whole 2.x framing is sound, not version-confused.
- **Optional error codes** `redundant-expr`, `truthy-bool`,
  `possibly-undefined`, `explicit-override` — all exist, off by default
  ([error_code_list2.html](https://mypy.readthedocs.io/en/stable/error_code_list2.html)).
- **`disallow_any_explicit`** description — quoted accurately.
- **ruff TC001/TC002/TC003** are the *current* codes (not the old TCH*) —
  confirmed on each rule page; matches the repo's `pyproject.toml`.
- **ty is beta, stable targeted "next year"** — confirmed via
  [ty blog](https://astral.sh/blog/ty); "10x–100x faster" matches the
  [ty docs](https://docs.astral.sh/ty/) homepage wording.

### Corrected
- **ruff FAQ / `ANN` claim.** The draft quoted ruff's FAQ as calling `ANN`
  "an equivalent to mypy's `disallow_untyped_defs`." That quotation is **not
  in the ruff FAQ** (verified by fetch + search). Fix: removed the false
  quote; kept the accurate, weaker point — `ANN` lints annotation
  *presence*, overlapping the *intent* of `disallow_untyped_defs`, while
  mypy additionally checks *correctness*. Source narrowed to what the FAQ
  actually says (recommends pairing ruff with a type checker).
- **ty intro misattribution.** The draft attributed "strict mode still on
  the roadmap, not shipped" to the [ty blog](https://astral.sh/blog/ty);
  the blog does not mention strict mode. Fix: re-sourced the no-strict-mode
  claim to ty's rules reference (where the doc already correctly cites it
  below) and replaced the loose "10–100×" with the docs' exact "10x - 100x"
  wording. Substance unchanged; citation now matches the source.

### Added (high-value, repo-relevant)
- **`disallow_any_generics`** as a first-class checkable rule, explicitly
  tied to this repo's `Entry = dict[str, Any]` alias in `scripts/extract.py`
  (the brief flagged this gap) — bare `dict`/`list`/`tuple` is a strict
  finding.
- **`strict_equality`, `warn_return_any`** broken out as checkable rules;
  `warn_return_any` specifically noted as the strict member that bites
  `json.loads(...) -> Entry` code.
- **`no_implicit_optional` is on by default** (since mypy 0.980) — write
  `T | None` explicitly; verified against command_line.html.
- **`--strict-bytes` became default in mypy 2.0** (PEP 688) — independent
  of `--strict`; verified against the 2.0 blog/changelog.
- **Untyped-decorator handling** (`disallow_untyped_decorators` in strict)
  and **`reveal_type` for debugging** (+ optional `unimported-reveal`).
- **`exclude` vs explicit `files`**: `exclude` only filters recursive
  discovery; explicitly-listed/import-reached files are still checked
  (mypy [#11760](https://github.com/python/mypy/issues/11760)).
- **Gradual-adoption strategy** (ratchet strictness; raise-strictness
  per-module overrides) — marked N/A for this already-strict repo but useful
  when the checklist is reused.

### Removed / softened as not fully verifiable
- Did **not** assert exact `force_exclude` semantics — could not pull a
  primary quote for its precise wording in this pass, so reduced it to a
  one-line aside (exists for the discovery case; not needed here) rather
  than a sourced claim.
