#!/usr/bin/env bash
# nix-cache-push-bundle DIR COMMAND [ARG]...
# Stream a nix-cache-bundle output directory to a cache-drop-<repo> account:
# a tar of exactly the top-level members the importer accepts (nix-cache-info,
# manifest.json, *.narinfo, nar/), zstd-compressed, on the stdin of COMMAND
# (normally the ssh invocation). Anything else in DIR (log/, realisations/,
# strays) is left out, so the receiver never rejects a bundle for it. Prints
# what the receiver prints ("ok") and exits with COMMAND's status.
set -euo pipefail
if [ "$#" -lt 2 ] || [ ! -f "${1:-}/manifest.json" ]; then
  echo "usage: nix-cache-push-bundle DIR COMMAND [ARG]... (DIR must hold manifest.json)" >&2
  exit 2
fi
dir=$1
shift
(
  cd -- "$dir"
  find . -maxdepth 1 \( -name '*.narinfo' -o -name nix-cache-info -o -name manifest.json -o -name nar \) -printf '%P\n' \
    | tar -cf - --files-from=-
) | zstd -3 -T0 -q -c | "$@"
