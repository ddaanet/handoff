# claude-plugin-dev — toolkit dev recipes.

_default:
    @just --list

# Run all syntax + style checks on the toolkit's own scripts.
precommit: whitespace
    shellcheck install.sh version-guard.sh
    bash -n tests/hook-test.sh
    just _import-check
    bash tests/hook-test.sh
    @echo ok

# Cut a new toolkit release: bump VERSION, commit, tag, push main + tag,
# create GitHub release. Pass `--yes` to skip the interactive confirmation.
release bump='patch' yes='': precommit
    #!/usr/bin/env bash
    set -euo pipefail
    git diff --quiet HEAD || { echo "error: uncommitted changes" >&2; exit 1; }
    branch=$(git symbolic-ref -q --short HEAD || echo "")
    main_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo "main")
    [ "$branch" = "$main_branch" ] || { echo "error: must be on $main_branch (currently $branch)" >&2; exit 1; }
    [ -f VERSION ] || { echo "error: VERSION file missing" >&2; exit 1; }
    file_version=$(tr -d '[:space:]' < VERSION)
    latest_tag=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
    if [ -n "$latest_tag" ] && [ "$file_version" != "$latest_tag" ]; then
      echo "error: VERSION ($file_version) does not match latest tag (v$latest_tag)" >&2
      echo "hint: VERSION holds the LAST released version. \`just release\` bumps from there." >&2
      echo "      revert any manual VERSION bump and re-run." >&2
      exit 1
    fi
    IFS=. read -r maj min pat <<< "$file_version"
    case "{{bump}}" in
      major) new_version="$((maj+1)).0.0" ;;
      minor) new_version="$maj.$((min+1)).0" ;;
      patch) new_version="$maj.$min.$((pat+1))" ;;
      *) echo "error: unknown bump type: {{bump}}" >&2; exit 1 ;;
    esac
    tag="v$new_version"
    git rev-parse "$tag" >/dev/null 2>&1 && { echo "error: tag $tag already exists" >&2; exit 1; }
    if [ "{{yes}}" != "--yes" ]; then
        read -rp "Release $new_version? [y/N] " answer
        case "$answer" in y|Y) ;; *) exit 1 ;; esac
    fi
    printf '%s\n' "$new_version" > VERSION
    git add VERSION
    git commit -m "release: $new_version"
    git tag -a "$tag" -m "Release $new_version"
    git push
    git push origin "$tag"
    gh release create "$tag" --title "Release $new_version" --generate-notes
    echo "Release $tag complete"

# Apply `git stripspace` to cached text files. Prints each file
# modified; never blocks the recipe.
whitespace:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r f; do
        tmp=$(mktemp)
        git stripspace < "$f" > "$tmp"
        if cmp -s "$f" "$tmp"; then
            rm -f "$tmp"
        else
            mv "$tmp" "$f"
            git add "$f"
            echo "whitespace: $f"
        fi
    done < <(git ls-files | grep -E '(^justfile$|\.(sh|md|just)$)')

# Install .git/hooks/pre-commit so `git commit` runs `just precommit`
# automatically. Idempotent: overwrites any existing hook.
install-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    hook=".git/hooks/pre-commit"
    cat > "$hook" <<'EOF'
    #!/bin/sh
    exec just precommit
    EOF
    chmod +x "$hook"
    echo "installed $hook"

# Import release.just into a stub consumer to catch justfile syntax errors.
[private]
_import-check:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    printf "import '%s/release.just'\n\nprecommit:\n    @echo stub\n" "$PWD" > "$tmp/justfile"
    just --justfile "$tmp/justfile" --list >/dev/null
    echo "release.just import: ok"
