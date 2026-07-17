import 'plugin-dev/release.just'

# handoff plugin — dev recipes

# Default: list recipes
_default:
    @just --list

# Lint manifests + settings, syntax-check + lint/type-check the Python
# (mypy AND ty — ty catches Any-narrowing holes mypy launders through;
# its version is locked, so gating it can't break the build spontaneously),
# run hook + pytest suites. Imported `release` recipe depends on this name.
precommit:
    jq . .claude-plugin/plugin.json > /dev/null
    jq . hooks/hooks.json > /dev/null
    jq . .claude/settings.json > /dev/null
    shellcheck -x .bin/* bin/* scripts/*.sh tests/*.bats
    ruff check scripts tests
    ruff format --check scripts tests
    docformatter --check scripts/*.py tests/*.py
    mypy
    ty check
    bats tests/hook-test.bats tests/rename-test.bats tests/memory-probe.bats tests/precompact-probe.bats
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

# Run the hook + rename test suites (bats) against synthetic tool-event input
hook-test:
    bats tests/hook-test.bats tests/rename-test.bats tests/memory-probe.bats tests/precompact-probe.bats

# Run the Python unit tests (pytest) — worktree_root.py resolver
py-test:
    pytest