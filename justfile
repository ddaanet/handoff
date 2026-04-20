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

# Create release: bump plugin.json version, commit, tag, push, GH release
release bump='patch': validate
    #!/usr/bin/env bash
    set -euo pipefail
    manifest=".claude-plugin/plugin.json"
    git diff --quiet HEAD || { echo "error: uncommitted changes" >&2; exit 1; }
    branch=$(git symbolic-ref -q --short HEAD || echo "")
    [ "$branch" = "main" ] || { echo "error: must be on main (currently $branch)" >&2; exit 1; }
    new_version=$(jq -r --arg bump "{{bump}}" '
      (.version | split(".") | map(tonumber)) as [$maj,$min,$pat]
      | if   $bump == "major" then [$maj+1, 0, 0]
        elif $bump == "minor" then [$maj, $min+1, 0]
        elif $bump == "patch" then [$maj, $min, $pat+1]
        else error("unknown bump type: " + $bump) end
      | map(tostring) | join(".")
    ' "$manifest")
    tag="v$new_version"
    git rev-parse "$tag" >/dev/null 2>&1 && { echo "error: tag $tag already exists" >&2; exit 1; }
    read -rp "Release $new_version? [y/N] " answer
    case "$answer" in y|Y) ;; *) exit 1 ;; esac
    tmp=$(mktemp)
    jq --arg v "$new_version" '.version = $v' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"
    git add "$manifest"
    git commit -m "chore: release $new_version"
    git tag -a "$tag" -m "Release $new_version"
    git push
    git push origin "$tag"
    gh release create "$tag" --title "Release $new_version" --generate-notes
    echo "Release $tag complete"

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
