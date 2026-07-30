import 'plugin-dev/release.just'

# handoff plugin — dev recipes
#
# `precommit` is the gate that runs before every commit: it lints the
# manifests + settings, syntax-checks and lint/type-checks the Python
# (mypy AND ty — ty catches Any-narrowing holes mypy launders through;
# its version is locked, so gating it can't break the build
# spontaneously), and runs the hook + pytest suites.
#
# `prerelease` is the gate the imported `release` recipe depends on.
# Here it is exactly `precommit`; widen it if the release ever needs
# checks too slow or too costly to fire on every commit.

# Default: list recipes
_default:
    @just --list

# Lint manifests + settings, lint/type-check the Python, run hook + pytest suites
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
    bats tests/hook-test.bats tests/watcher-test.bats tests/checkpoint.bats
    pytest
    @echo "ok"

# Gate the imported `release` recipe depends on
prerelease: precommit

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
    bats tests/hook-test.bats tests/watcher-test.bats tests/checkpoint.bats

# Run the Python unit tests (pytest) — worktree_root.py resolver
py-test:
    pytest