# The "playground" package set: third-party packages we want at their latest
# upstream commit rather than the (often stale) nixpkgs revision. Sources are
# tracked by nvfetcher (./nvfetcher.toml -> ./_sources); only the per-package
# build metadata lives here. Mirrors nix/pkgs/vimPlugins.
#
# Once nvfetcher.toml has an entry, generate its source with:
#   nix develop -c nvfetcher -c nix/pkgs/playground/nvfetcher.toml -o nix/pkgs/playground/_sources -f <name>
# where <name> is the section name in nvfetcher.toml.
{pkgs}: let
  sources = pkgs.callPackage ./_sources/generated.nix {};
in {
  workstyle = pkgs.callPackage ./workstyle.nix {
    source = sources.workstyle;
  };
}
