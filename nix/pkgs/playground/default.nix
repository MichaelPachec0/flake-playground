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
  electron-mail = pkgs.callPackage ./electron-mail.nix {
    source = sources.electron-mail;
  };
  affine-mcp-server = pkgs.callPackage ./affine-mcp-server.nix {
    source = sources.affine-mcp-server;
  };
  # Multi-arch: pick the nvfetcher source whose pinned digest matches the build
  # host platform (amd64 vs arm64). Both track the same AFFiNE release.
  affine-server = pkgs.callPackage ./affine-server.nix {
    source =
      if pkgs.stdenv.hostPlatform.isAarch64
      then sources.affine-server-arm64
      else sources.affine-server;
  };
}
