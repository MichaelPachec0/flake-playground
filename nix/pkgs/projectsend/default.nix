# ProjectSend package. Source pinned by nvfetcher (./nvfetcher.toml ->
# ./_sources); build metadata lives in ./package.nix.
{
  pkgs,
  withRedis ? true,
  stateDir ? "/var/lib/projectsend",
}: let
  sources = pkgs.callPackage ./_sources/generated.nix {};
in
  pkgs.callPackage ./package.nix {
    source = sources.projectsend;
    inherit withRedis stateDir;
  }
