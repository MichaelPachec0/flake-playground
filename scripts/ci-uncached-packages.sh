#!/usr/bin/env bash
# Print the guarded packages that would have to be built from source.
#
# Some packages are only worth having in CI when a binary cache serves them:
# cynthion rebuilds its FPGA gateware for every board revision, about 23
# minutes on a GitHub runner, which alone eats most of a job's time limit. For
# each attr name given, this asks nix (through the daemon, so every configured
# substituter and its credentials count, plus the local store) whether the
# package's own derivation would be built. Names that would are printed on
# stdout, space separated, with a GitHub Actions warning each. The nix-checks
# action exports that list as CI_SKIP_PACKAGES, which the `packages` check
# reads to leave them out.
#
# A package that fails to evaluate is NOT skipped: that is a real breakage the
# build step should report.
#
# Usage: scripts/ci-uncached-packages.sh <attr-name>...
set -euo pipefail

system=$(nix eval --raw --impure --expr builtins.currentSystem)
skip=()
for name in "$@"; do
  attr=".#packages.$system.$name"
  if ! drv=$(nix eval --raw "$attr.drvPath" 2>/dev/null); then
    echo "::notice::cache guard: $attr does not evaluate here; leaving it to the build" >&2
    continue
  fi
  # --dry-run lists the derivations nix would build after consulting the
  # substituters. Only the package's own derivation matters: a missing
  # dependency of a cached package is never built.
  if ! plan=$(nix build --dry-run "$attr" 2>&1); then
    echo "::notice::cache guard: dry run of $attr failed; leaving it to the build" >&2
    continue
  fi
  if grep -qF -- "$drv" <<<"$plan"; then
    echo "::warning::$name is in no binary cache (cache.nixos.org or the configured substituters); skipping it in the packages check instead of building it from source. Usual cause: an override changed its hash, or Hydra has not built it for this nixpkgs pin yet." >&2
    skip+=("$name")
  else
    echo "cache guard: $name is substitutable or already in the store" >&2
  fi
done
echo "${skip[*]:-}"
