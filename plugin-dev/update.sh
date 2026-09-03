#!/usr/bin/env bash
# Update the vendored claude-plugin-dev toolkit to a dist tag.
#
#     just update-plugin-dev [dist-vX.Y.Z]
#
# runs the vendored copy of this script. With no ref, the newest dist-
# tag on the remote is resolved and used. After the pull, migration
# notes for every version crossed are printed — guidance only, nothing
# outside plugin-dev/ is ever written.
set -euo pipefail

# Env-overridable so tests can point it at a local fixture repo.
TOOLKIT_URL="${TOOLKIT_URL:-git@github.com:ddaanet/claude-plugin-dev.git}"
TOOLKIT_PREFIX="plugin-dev"

ref="${1:-}"

git diff --quiet HEAD || { echo "error: uncommitted changes — commit or stash before updating" >&2; exit 1; }
[ -d "$TOOLKIT_PREFIX" ] || { echo "error: $TOOLKIT_PREFIX/ not found — is the toolkit vendored here?" >&2; exit 1; }

if [ -z "$ref" ]; then
    # Same resolver as install.sh's first-install default. Kept as a copy
    # there: the bootstrap script must stay runnable on its own, without
    # depending on a sibling file.
    ref="$(git ls-remote --tags --refs --sort=-v:refname "$TOOLKIT_URL" 'dist-v*' | sed -n '1s|.*/||p')"
    if [ -z "$ref" ]; then
        echo "error: could not resolve a dist tag from $TOOLKIT_URL" >&2
        echo "hint: pass one explicitly: just update-plugin-dev dist-vX.Y.Z" >&2
        exit 1
    fi
    echo "update-plugin-dev: resolved newest dist tag: $ref"
fi

# Only a dist tag is vendorable. Every other ref -- source tag, branch,
# sha -- resolves to the toolkit's root tree, which is its own working
# environment: a `memory` gitlink, .claude/, CLAUDE.md, its own justfile.
# Pulling one copies all of that into this plugin and is invisible until
# someone runs `git submodule status`, so it is refused, not warned about.
case "$ref" in
  dist-v*) ;;
  v*)
      echo "error: '$ref' is a source tag — pull the dist tag instead: dist-$ref" >&2
      exit 1
      ;;
  *)
      echo "error: '$ref' is not a dist tag — pull dist-vX.Y.Z" >&2
      echo "       only the dist lineage contains the consumer-facing files." >&2
      exit 1
      ;;
esac

# Captured before the pull: the migration-note range below needs the version
# this consumer is coming FROM, which the pull overwrites.
old_version=""
if [ -f "$TOOLKIT_PREFIX/VERSION" ]; then
    old_version="$(tr -d '[:space:]' < "$TOOLKIT_PREFIX/VERSION")"
fi

git subtree pull --prefix="$TOOLKIT_PREFIX" "$TOOLKIT_URL" "$ref" --squash

# Verify VERSION matches the requested tag (catches half-applied subtree
# pulls). Unconditional: the guard above means only a dist-v* ref reaches
# here, so the version is always extractable. Still best-effort on the
# file, which a ref older than v0.2.0 lacks.
expected="${ref#dist-v}"
new_version=""
if [ -f "$TOOLKIT_PREFIX/VERSION" ]; then
    new_version="$(tr -d '[:space:]' < "$TOOLKIT_PREFIX/VERSION")"
    [ "$new_version" = "$expected" ] \
        || echo "warning: $TOOLKIT_PREFIX/VERSION ($new_version) does not match requested ref ($ref)" >&2
fi

# Print the migration notes for every version crossed by this pull:
# old_version exclusive, new_version inclusive. Notes ship inside the dist
# tree at migrations/vX.Y.Z.md, one optional note per release; they are
# guidance for the human to apply, never executed.
version_gt() {
    # True when $1 is a strictly newer version than $2.
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

if [ -d "$TOOLKIT_PREFIX/migrations" ] && [ -n "$new_version" ]; then
    if [ -z "$old_version" ]; then
        echo "note: previous toolkit version unknown — review $TOOLKIT_PREFIX/migrations/ by hand." >&2
    else
        # Shipped paths only (dist-tree-test pins their shape), so
        # newline-delimited iteration is safe here.
        while IFS= read -r note; do
            [ -f "$note" ] || continue   # unmatched glob
            v="${note##*/v}"
            v="${v%.md}"
            if version_gt "$v" "$old_version" && ! version_gt "$v" "$new_version"; then
                printf -- '-- migration note v%s (%s) --\n' "$v" "$note"
                cat "$note"
            fi
        done < <(printf '%s\n' "$TOOLKIT_PREFIX"/migrations/v*.md | sort -V)
    fi
fi
