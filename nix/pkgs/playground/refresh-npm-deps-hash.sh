#!/usr/bin/env bash
# Recompute the buildNpmPackage npmDepsHash for a playground package after
# nvfetcher has bumped its source, and write it to <name>.npm-deps.hash next to
# the package. nvfetcher tracks version+source but cannot compute npmDepsHash;
# this closes that gap so the daily bump keeps the npm build valid.
#
# Usage: nix/pkgs/playground/refresh-npm-deps-hash.sh <nvfetcher-name>
#   e.g. nix/pkgs/playground/refresh-npm-deps-hash.sh affine-mcp-server
set -euo pipefail

name="${1:?usage: refresh-npm-deps-hash.sh <nvfetcher-name>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/${name}.npm-deps.hash"

# Realise just the pinned source tree, then hash its lockfile's deps.
src="$(nix-build --no-out-link -E \
  "((import <nixpkgs> {}).callPackage $here/_sources/generated.nix {}).\"${name}\".src")"

hash="$(nix run nixpkgs#prefetch-npm-deps -- "$src/package-lock.json")"

printf '%s\n' "$hash" > "$out"
echo "refreshed $out -> $hash"
