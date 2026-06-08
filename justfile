import 'plugin-dev/release.just'

# handoff plugin — dev recipes

# Default: list recipes
_default:
    @just --list

# Lint manifests + settings, syntax-check scripts, run hook tests.
# Imported `release` recipe depends on this name.
precommit:
    jq . .claude-plugin/plugin.json > /dev/null
    jq . hooks/hooks.json > /dev/null
    jq . .claude/settings.json > /dev/null
    python3 -c "import ast; ast.parse(open('scripts/extract.py').read())"
    shellcheck -x scripts/*.sh tests/*.sh tests/*.bats
    bats tests/hook-test.bats tests/rename-test.bats
    pytest
    @echo "ok"

# Assemble the handoff frame from an explicit transcript (testing)
extract transcript output:
    python3 scripts/extract.py {{transcript}} {{output}}

# Smoke test: extract against the most recent session JSONL
smoke:
    bash tests/smoke.sh

# Run the hook + rename test suites (bats) against synthetic tool-event input
hook-test:
    bats tests/hook-test.bats tests/rename-test.bats

# Run the extract.py tests (pytest) against the synthetic JSONL fixtures
extract-test:
    pytest