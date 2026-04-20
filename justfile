# handoff plugin — dev recipes

# Default: list recipes
_default:
    @just --list

# Validate manifests and script syntax
validate:
    jq . .claude-plugin/plugin.json > /dev/null
    jq . hooks/hooks.json > /dev/null
    python3 -c "import ast; ast.parse(open('scripts/extract.py').read())"
    bash -n scripts/stop-hook.sh
    @echo "ok"

# Extract handoff.md from an explicit transcript (testing)
extract transcript output:
    python3 scripts/extract.py {{transcript}} {{output}}

# Smoke test: extract against the most recent session JSONL
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    proj="$HOME/.claude/projects/-Users-david-code-handoff"
    transcript=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1 || true)
    if [ -z "$transcript" ]; then
        echo "no session transcript at $proj — open this dir in claude first" >&2
        exit 1
    fi
    output=$(mktemp --suffix=.md)
    python3 scripts/extract.py "$transcript" "$output"
    echo "--- $output ---"
    cat "$output"
    rm -f "$output"

# Dry-run the Stop hook against a synthetic task file
hook-test:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d)
    mkdir -p "$tmp/.claude"
    cat > "$tmp/.claude/handoff-task.md" <<'EOF'
    ## Current task

    hook smoke test

    ## Open decisions

    - none
    EOF
    transcript=$(ls -t "$HOME/.claude/projects/-Users-david-code-handoff"/*.jsonl 2>/dev/null | head -1 || echo "")
    printf '{"cwd":"%s","transcript_path":"%s"}' "$tmp" "$transcript" | bash scripts/stop-hook.sh
    echo "--- $tmp/.claude/handoff.md ---"
    cat "$tmp/.claude/handoff.md" || true
    rm -rf "$tmp"
