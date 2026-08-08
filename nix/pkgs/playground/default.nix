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
  powertop = pkgs.callPackage ./powertop.nix {
    source = sources.powertop;
  };
  electron-mail = pkgs.callPackage ./electron-mail.nix {
    source = sources.electron-mail;
  };
  affine-mcp-server = pkgs.callPackage ./affine-mcp-server.nix {
    source = sources.affine-mcp-server;
  };
  # Per-platform prebuilt tarballs: one nvfetcher entry per target, selected by
  # the build's host platform (see the freebuff-* entries in ./nvfetcher.toml).
  # All entries track the same npm version. `throw` is lazy, so an untracked
  # platform only fails when this attribute is actually forced -- importing the
  # playground set on, say, x86_64-darwin stays fine.
  freebuff = pkgs.callPackage ./freebuff.nix {
    source =
      sources."freebuff-${
        {
          x86_64-linux = "linux-x64";
          aarch64-linux = "linux-arm64";
          aarch64-darwin = "darwin-arm64";
        }
        .${pkgs.stdenv.hostPlatform.system}
        or (throw "freebuff: no nvfetcher source tracked for ${pkgs.stdenv.hostPlatform.system}; add an entry to nix/pkgs/playground/nvfetcher.toml and a case here")
      }";
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
