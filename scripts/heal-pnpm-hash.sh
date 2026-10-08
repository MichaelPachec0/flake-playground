#!/usr/bin/env bash
# Recompute a package's pnpm deps hash when it is stale.
#
# nvfetcher pins a package's source but cannot compute the fixed-output hash of
# its pnpm dependency store, so that hash lives in a companion file next to the
# package. When upstream changes pnpm-lock.yaml, the file falls behind. This
# builds `.#<attr>.pnpmDeps`; on a hash mismatch it writes the hash Nix reports,
# rebuilds to confirm, and emits a GitHub Actions warning. Any OTHER failure
# (network, lockfile, pnpm) is fatal: here the heal step IS the dependency
# fetch, so swallowing its errors would hide a broken bump.
#
# Usage: scripts/heal-pnpm-hash.sh <flake-attr> <hash-file>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <flake-attr> <hash-file>" >&2
  exit 2
fi

attr=$1
hash_file=$2
log=$(mktemp)
trap 'rm -f "$log"' EXIT

build() {
  nix build -L --no-link ".#${attr}.pnpmDeps" >"$log" 2>&1
}

if build; then
  exit 0
fi

if ! grep -q 'hash mismatch in fixed-output derivation' "$log"; then
  echo "::error::${attr} pnpmDeps failed for a reason other than a stale hash" >&2
  tail -n 40 "$log" >&2
  exit 1
fi

new=$(sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' "$log" | tail -n 1)
if [ -z "$new" ]; then
  echo "::error::${attr} hash mismatch but no 'got:' hash found in the log" >&2
  tail -n 40 "$log" >&2
  exit 1
fi

old=$(tr -d '[:space:]' <"$hash_file")
printf '%s\n' "$new" >"$hash_file"

if ! build; then
  echo "::error::${attr} pnpmDeps still fails after writing ${new}" >&2
  tail -n 40 "$log" >&2
  exit 1
fi

echo "::warning::${attr} pnpm deps hash was stale (${old} -> ${new}); updated ${hash_file}"
