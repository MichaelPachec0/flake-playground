# zipline-latest: Zipline at its latest upstream stable release. Source pinned
# by nvfetcher (./nvfetcher.toml -> ./_sources); build lives in ./package.nix.
{pkgs}: let
  sources = pkgs.callPackage ./_sources/generated.nix {};
in
  pkgs.callPackage ./package.nix {source = sources.zipline;}
