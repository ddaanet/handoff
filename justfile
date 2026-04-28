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
