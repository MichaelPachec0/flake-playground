# DAWNCR0W/affine-mcp-server: write-capable MCP server for AFFiNE, built from
# the nvfetcher-pinned latest GitHub release (`source` = an entry from
# ./_sources/generated.nix). Consumed by the `mcp.affine` NixOS module, which
# execs $out/lib/node_modules/affine-mcp-server/dist/index.js under node.
#
# NO npmDepsHash. buildNpmPackage's default vendoring wants a single hash over
# the whole dependency closure, which nvfetcher cannot compute -- so it had to
# live in a companion file, and every source bump silently invalidated it.
# Instead the nvfetcher entry `extract`s package.json + package-lock.json into
# _sources/ (plain files in the repo, see ./nvfetcher.toml), and importNpmLock
# turns the lockfile into one fixed-output fetch per dependency, each hashed by
# the `integrity` field npm already recorded. Deps therefore update atomically
# with the source pin: nothing to refresh, nothing to drift.
#
# Trade-off: hundreds of small FODs instead of one large one -- a cold build
# makes many more network round-trips than the old single vendored tarball.
{
  lib,
  buildNpmPackage,
  importNpmLock,
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

  # Read the manifests from the EXTRACTED copies, never from `src`. Reading them
  # off the fetchFromGitHub store path would be import-from-derivation: eval
  # would have to build the source first, which breaks the eval-only checks.
  #
  # `importNpmLock` is called as a FUNCTION here (the attrset carries a
  # `__functor`), not via its `buildNodeModules` attribute. The two are not
  # interchangeable: buildNodeModules realises an actual node_modules tree for
  # `linkNodeModulesHook`/dev shells, whereas npmConfigHook wants the rewritten
  # package.json + package-lock.json -- the ones whose `resolved` fields point at
  # store paths instead of registry.npmjs.org. Pass the former and the build dies
  # mid-install with `npm error code ENOTCACHED ... cache mode is 'only-if-cached'`
  # on the first dependency, because npm is still reading the unpatched lockfile.
  npmDeps = importNpmLock {
    package = lib.importJSON source.extract."package.json";
    packageLock = lib.importJSON source.extract."package-lock.json";
  };
  # importNpmLock links its per-package store paths into node_modules; the stock
  # npmConfigHook only understands the vendored-tarball layout, so it must be
  # swapped out alongside npmDeps.
  npmConfigHook = importNpmLock.npmConfigHook;

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
