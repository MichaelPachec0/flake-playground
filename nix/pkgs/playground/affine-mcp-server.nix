# DAWNCR0W/affine-mcp-server — write-capable MCP server for AFFiNE, built from
# the nvfetcher-pinned latest GitHub release (`source` = an entry from
# ./_sources/generated.nix). Consumed by the `mcp.affine` NixOS module, which
# execs $out/lib/node_modules/affine-mcp-server/dist/index.js under node.
#
# npmDepsHash (the vendored node_modules hash) is NOT computed by nvfetcher, so
# it lives in ./affine-mcp-server.npm-deps.hash and is refreshed together with
# the source pin by .github/workflows/update-playground.yml. To bump it by hand:
#   src=$(nix-build --no-out-link -E '((import <nixpkgs> {}).callPackage ./nix/pkgs/playground/_sources/generated.nix {})."affine-mcp-server".src')
#   nix run nixpkgs#prefetch-npm-deps -- "$src/package-lock.json" > nix/pkgs/playground/affine-mcp-server.npm-deps.hash
{
  lib,
  buildNpmPackage,
  nodejs_22,
  source,
}:
buildNpmPackage {
  inherit (source) pname src;
  # The nvfetcher entry keeps the leading `v` in version (see nvfetcher.toml:
  # fetch.github reuses version as the git rev, and the tag is v3.0.1). Strip it
  # here so the derivation version is bare semver (3.0.1).
  version = lib.removePrefix "v" source.version;

  # Upstream requires Node >= 20; pin the toolchain the module also runs under.
  nodejs = nodejs_22;

  # nvfetcher can't produce this; kept in a generated companion file (CI-refreshed).
  npmDepsHash = lib.fileContents ./affine-mcp-server.npm-deps.hash;

  # package.json "build" = `npm run clean && tsc -p tsconfig.json` -> dist/.
  npmBuildScript = "build";

  # Upstream tests pull in Playwright + a live AFFiNE; skip in the sandbox.
  doCheck = false;

  meta = {
    description = "Write-capable Model Context Protocol server for AFFiNE workspaces";
    homepage = "https://github.com/DAWNCR0W/affine-mcp-server";
    license = lib.licenses.mit;
    mainProgram = "affine-mcp";
    platforms = lib.platforms.linux;
  };
}
