#!/usr/bin/env bash
# SessionEnd: confirm `/exit` for a restart transition in flight. Fires on
# every session end (interactive /exit, other reasons, a crash), so the
# no-transition path must stay cheap and silent.
#
# Writes .claude/autodrive.exited, which the walker's submit_exited polls
# for: SessionEnd is the harness-authoritative signal that the process is
# gone, not a pane-scraped one. stop-drive.sh clears any stale copy before
# spawning the walker, so a leftover from an earlier, only-partly-successful
# restart cannot false-positive a later one.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

hook_cwd="$(jq -r '.cwd // ""')"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

drive="$cwd/$HANDOFF_REL_DRIVE"
[[ -f "$drive" ]] || exit 0

handoff_drive_read "$drive" || exit 0
[[ "$DRIVE_STATE" == "pending" && "$DRIVE_KIND" == "restart" ]] || exit 0

: > "$cwd/$HANDOFF_REL_DRIVE_EXITED"
