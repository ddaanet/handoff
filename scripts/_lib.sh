#!/usr/bin/env bash
# Shared helpers for handoff hook scripts. Source-only; no shebang
# execution. Source from siblings via:
#   # shellcheck source=_lib.sh
#   source "$(dirname "$0")/_lib.sh"

# Canonical relative paths inside the project. Changing these is a
# breaking change (see CLAUDE.md conventions).
# shellcheck disable=SC2034  # consumed by sourcing scripts
HANDOFF_REL_TASK=".claude/handoff-task.md"
# shellcheck disable=SC2034
HANDOFF_REL_OUT=".claude/handoff.md"
# shellcheck disable=SC2034
HANDOFF_REL_ERR=".claude/handoff-error.log"

# Portable path canonicalization. `realpath -m` is GNU-only; BSD
# `realpath` rejects non-existent components. Python handles both and
# resolves multiple paths in one subprocess to amortize cold start.
# Prints one line per argument, in order.
handoff_resolve() {
    python3 -c 'import os,sys
for p in sys.argv[1:]: print(os.path.realpath(p))' "$@"
}
