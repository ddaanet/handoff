import 'plugin-dev/release.just'

# handoff plugin — dev recipes

# Default: list recipes
_default:
    @just --list

# Lint manifests + settings, syntax-check + lint/type-check the Python
# (mypy AND ty — ty catches Any-narrowing holes mypy launders through;
# its version is locked, so gating it can't break the build spontaneously),
# run hook + extract tests. Imported `release` recipe depends on this name.
precommit:
    jq . .claude-plugin/plugin.json > /dev/null
    jq . hooks/hooks.json > /dev/null
    jq . .claude/settings.json > /dev/null
    python3 -c "import ast; ast.parse(open('scripts/extract.py').read())"
    shellcheck -x scripts/*.sh tests/*.sh tests/*.bats
    ruff check scripts tests
    ruff format --check scripts tests
    docformatter --check scripts/*.py tests/*.py
    mypy
    ty check
    bats tests/hook-test.bats tests/rename-test.bats tests/memory-probe.bats
    pytest
    @echo "ok"

# Ruff + docformatter over the Python (lint/format only, no type check).
lint:
    ruff check scripts tests
    ruff format --check scripts tests
    docformatter --check scripts/*.py tests/*.py

# Both type checkers, strict mypy + ty. Both gate precommit.
typecheck:
    mypy
    ty check

# ty (preview) alone — for reading ty's diagnostics in isolation.
ty:
    ty check

# Assemble the handoff frame from an explicit transcript (testing)
extract transcript output:
    python3 scripts/extract.py {{transcript}} {{output}}

# Smoke test: extract against the most recent session JSONL
smoke:
    bash tests/smoke.sh

# Run the hook + rename test suites (bats) against synthetic tool-event input
hook-test:
    bats tests/hook-test.bats tests/rename-test.bats tests/memory-probe.bats

# Run the extract.py tests (pytest) against the synthetic JSONL fixtures
extract-test:
    pytest