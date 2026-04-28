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
    bash -n scripts/skill-pre-hook.sh
    bash -n scripts/prompt-pre-hook.sh
    bash -n scripts/write-guard.sh
    bash -n scripts/write-extract.sh
    bash -n tests/hook-test.sh
    bash -n tests/smoke.sh
    bash tests/hook-test.sh
    @echo "ok"

# Extract handoff.md from an explicit transcript (testing)
extract transcript output:
    python3 scripts/extract.py {{transcript}} {{output}}

# Smoke test: extract against the most recent session JSONL
smoke:
    bash tests/smoke.sh

# Run the hook test suite against synthetic tool-event input
hook-test:
    bash tests/hook-test.sh