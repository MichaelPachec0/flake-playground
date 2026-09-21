# PICR (self-hosted photo-sharing server) built from source, plus its Ping
# sidecar. Source tracked by nvfetcher (./nvfetcher.toml -> ./_sources); build
# metadata lives here. Own bump workflow (.github/workflows/update-picr.yml)
# keeps this out of the daily playground bump. Mirrors nix/pkgs/vimPlugins.
{pkgs}: let
  sources = pkgs.callPackage ./_sources/generated.nix {};
in {
  picr = pkgs.callPackage ./picr.nix {source = sources.picr;};
  picr-ping = pkgs.callPackage ./picr-ping.nix {source = sources.picr;};
}
