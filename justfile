# handoff plugin — dev recipes

# Default: list recipes
_default:
    @just --list

# Validate manifests and script syntax
validate:
    jq . .claude-plugin/plugin.json > /dev/null
    jq . hooks/hooks.json > /dev/null
    python3 -c "import ast; ast.parse(open('scripts/extract.py').read())"
    bash -n scripts/skill-pre-hook.sh
    bash -n scripts/prompt-pre-hook.sh
    bash -n scripts/write-guard.sh
    bash -n scripts/write-extract.sh
    bash -n tests/hook-test.sh
    bash -n tests/smoke.sh
    @echo "ok"

# Extract handoff.md from an explicit transcript (testing)
extract transcript output:
    python3 scripts/extract.py {{transcript}} {{output}}

# Smoke test: extract against the most recent session JSONL
smoke:
    bash tests/smoke.sh

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

# Run the hook test suite against synthetic tool-event input
hook-test:
    bash tests/hook-test.sh
