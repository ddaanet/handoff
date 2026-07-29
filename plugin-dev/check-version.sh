#!/usr/bin/env bash
set -euo pipefail

# Fail when a consumer plugin's version drifts from the version recorded
# for it in the marketplace repo. `release.just`'s `release` recipe bumps
# `.claude-plugin/plugin.json` and commits/tags/pushes it *before* creating
# the GitHub release and bumping the marketplace entry; if anything from
# that point on fails, plugin.json (and the pushed tag) are already at the
# new version while the marketplace entry is stale. `/plugin marketplace
# update` surfaces the marketplace value, so drift misreports the
# installed version.
#
# Usage: check-version.sh [PLUGIN_JSON] [MARKETPLACE_JSON]
# PLUGIN_JSON defaults to ../.claude-plugin/plugin.json relative to this
# script (i.e. the consumer plugin vendoring this toolkit at plugin-dev/).
# MARKETPLACE_JSON defaults to $MARKETPLACE_DIR/.claude-plugin/marketplace.json.
# Run via `just check-version` (see release.just).

unset CDPATH   # else `cd` may echo its target into the $(cd … && pwd) captures below
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd "$here/.." && pwd)"

plugin_json="${1:-$plugin_root/.claude-plugin/plugin.json}"

if [ -n "${2:-}" ]; then
  marketplace_json="$2"
elif [ -n "${MARKETPLACE_DIR:-}" ]; then
  marketplace_json="$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
else
  echo "check-version: MARKETPLACE_DIR not set — skip" >&2
  exit 0
fi

# The marketplace repo may not be checked out (fresh clone, CI without it).
# Skipping keeps the check non-fatal where it can't run; it only guards on
# machines where both repos are present.
if [ ! -f "$marketplace_json" ]; then
  echo "check-version: marketplace.json not found at $marketplace_json — skip" >&2
  exit 0
fi

plugin_name="$(jq -r '.name' "$plugin_json")"
plugin_ver="$(jq -r '.version' "$plugin_json")"
market_ver="$(jq -r --arg n "$plugin_name" '.plugins[] | select(.name==$n) | .version' "$marketplace_json")"

if [ -z "$market_ver" ] || [ "$market_ver" = "null" ]; then
  # No entry yet is the pre-first-publication state (see release.just's
  # marketplace step), not drift — nothing to compare against.
  echo "check-version: no $plugin_name entry in $marketplace_json — skip" >&2
  exit 0
fi

if [ "$plugin_ver" != "$market_ver" ]; then
  echo "check-version: version drift — plugin.json=$plugin_ver marketplace.json=$market_ver" >&2
  echo "  bump both to the same value before release." >&2
  exit 1
fi

echo "check-version: in sync ($plugin_ver)"
