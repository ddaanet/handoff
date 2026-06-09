# mypy guidelines — review checklist

Engineering-grade rules for type-checking Python with mypy (plus ruff and
ty). Phrased as checkable DO/AVOID rules so code can be audited against
them. Each non-obvious claim cites a primary source inline.

Verified against mypy **2.1.0** stable. mypy **2.0** changed two defaults
that matter here (`--strict-bytes`, `local_partial_types`), so a project
on a `mypy>=1.x` floor that nonetheless resolves a 2.x interpreter still
sees the 2.x behavior — pin the version if you depend on either. Sources
are listed at the bottom; URLs are also inlined at each claim.

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
  and is why a JSON-entry alias is spelled `Json = dict[str, Any]` rather
  than `Json = dict`. **DO write fully-parameterised generics** (`list[str]`,
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
  code it is usually too blunt; prefer typing the boundary (below) over a
  global ban.
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
  This is how modules in a flat source dir resolve without a package
  prefix — mirroring pytest's `pythonpath`. Use `packages =` only for real
  importable packages with `__init__.py`.
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
  [#11760](https://github.com/python/mypy/issues/11760)). Rule: if a
  file you expected to be skipped is still type-checked, it's reachable via
  `files`/`mypy_path` — narrow `files` rather than expecting `exclude` to
  override it. (`force_exclude` exists for the discovery case but is not
  needed when files are listed explicitly.)
- **For gradual adoption** (introducing strict mypy into an untyped
  codebase), don't flip `strict = true` globally on day one. Start with the
  default (lenient) config, then ratchet: enable one strict sub-flag at a
  time, or scope strictness to already-clean modules via a per-module
  override that *raises* strictness (the inverse of the loosening overrides
  warned against above), then widen
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
  A small, already-strict codebase needs none of this; the ratchet is for
  introducing strict mypy into a large untyped codebase.
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
  a real boundary, not a hole. A commented alias such as
  `Json = dict[str, Any]  # undocumented, evolving format` parameterises the
  generic (satisfying `disallow_any_generics`) while owning the `Any` as a
  deliberate, documented boundary. Narrow to concrete types as soon as you
  read a field. **DO comment the alias** so the `Any` reads as intentional,
  not lazy.

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
  rename is one edit and a typo is a type error. Caveat: when the
  surrounding dict stays `Any` at the boundary, a `Literal` annotation on a
  value read from it is erased on contact (mypy won't check `Any` against a
  `Literal`), so the realisable win is often just the de-duplication of a
  named constant, not new checking — weigh the heavier `Literal`/`Enum`
  against that before reaching for it.
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
  context: in an application, often worth it; in a stdlib-only script with
  no runtime deps by design, it's the heaviest option and likely overkill —
  a `TypedDict` + narrowing carries no dependency.

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
  an untyped def and mypy will flag it. Keep the whole test suite annotated.
- **DON'T let an untyped decorator erase a function's signature.**
  `disallow_untyped_decorators` (in `--strict`) flags decorating a typed
  function with an untyped decorator
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)),
  because an untyped decorator makes the decorated function `Any`,
  silently dropping its annotations. For pytest, `@pytest.fixture` and
  `@pytest.mark.*` are typed in modern `pytest` (≥8), so this should not
  fire; if it does, the fix is a properly-typed decorator, not a per-line
  ignore.
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
  defs/args/returns. With `select = ["ALL"]` you get `ANN` for
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
  Deliberately ignoring `TC001`–`TC003` is a defensible choice for small
  scripts where the runtime-import cost is negligible and `TYPE_CHECKING`
  blocks add noise; for a large or import-heavy codebase, leave them on.
  Either way, make the call explicit in config rather than by accident.
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
  enforce a strict-defs contract — mypy remains the gate.
- **Different defaults and narrowing.** ty checks all code by default
  (including untyped), and its design centers the "gradual guarantee":
  adding annotations to working code never introduces new errors
  ([ty docs](https://docs.astral.sh/ty/)). Its narrowing and reachability
  analysis differ from mypy's, so the two can legitimately disagree — a ty
  finding is a prompt to investigate, not an automatic mypy bug.
- **No plugin system** (and no plans for one), so ty can't replace mypy
  where ORM/Pydantic plugins matter
  ([ty github](https://github.com/astral-sh/ty)). Irrelevant if you use no
  mypy plugins, but check before adopting ty anywhere.
- **Suppression syntax differs.** ty understands standard
  `# type: ignore`, plus its own `# ty: ignore[code]` and
  `# type: ignore[ty:code]`
  ([ty rules](https://docs.astral.sh/ty/reference/rules/)). A code that
  matches no known rule suppresses nothing.
- **DO run ty alongside mypy** (wire it as a preview under `[tool.ty]`):
  green-on-both raises confidence; a divergence is a signal to read both
  tools' reasoning. ty's stricter narrowing legitimately catches some
  `Any`-laundering holes mypy passes, so it earns more than a manual probe.
  **DO gate on ty *in addition to* mypy** when its version is pinned (a
  locked beta can't break the build spontaneously — only on a deliberate
  bump, where a genuine false positive is suppressed narrowly with
  `# ty: ignore[code]`, not by dropping the gate). **DON'T** gate on ty
  *alone*, or drop mypy for it — it has no strict-defs contract (above).

## Practical gotchas

- **Third-party stubs.** For libraries shipping no inline types, install
  the `types-*` stub package (e.g. `types-requests`); mypy emits
  `import-untyped` / `no-any-unimported` otherwise. A stdlib-only project
  needs no stubs — but don't paper over a missing stub with a module-level
  `ignore_missing_imports` override when a `types-*` package exists.
- **Flat modules vs namespace packages.** With no `__init__.py` (a flat
  source dir), mypy resolves imports via `mypy_path`, pytest via
  `pythonpath` + `--import-mode=importlib`. `namespace_packages`
  defaults to `True` (PEP 420)
  ([config_file.html](https://mypy.readthedocs.io/en/stable/config_file.html)).
  Keep the path settings of each tool (mypy `mypy_path`, pytest
  `pythonpath`, ty `extra-paths`) in sync — they should all point at the
  same source dir; drift breaks one tool silently. Avoid same-named modules
  in two unpackaged dirs: importlib mode can't disambiguate them.
- **`warn_redundant_casts`** (in `--strict`) flags casts that change
  nothing; treat its findings as "delete the cast," not "add an ignore."
- **`no_implicit_reexport`** (in `--strict`) means a name imported into a
  module is NOT re-exported unless imported via `from ... import x as x`
  or listed in `__all__`
  ([command_line.html](https://mypy.readthedocs.io/en/stable/command_line.html)).
  If a test imports a helper that another module merely re-imported,
  expect an `attr-defined` error — fix the source module's `__all__`,
  don't suppress.

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

