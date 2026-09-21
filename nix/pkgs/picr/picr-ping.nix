# PICR Ping: small Node sidecar that watches the media filesystem and posts
# reconciliation hints to a PICR server. No native addons. Built from the picr
# source tree (the `ping/` workspace plus the three `shared/` files it imports).
{
  lib,
  stdenv,
  importNpmLock,
  nodejs_24,
  makeWrapper,
  source,
}: let
  nodejs = nodejs_24;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "picr-ping";
    inherit (source) version;
    src = source.src;

    nativeBuildInputs = [nodejs importNpmLock.hooks.linkNodeModulesHook makeWrapper];

    # importNpmLock reads ping/package-lock.json and stages node_modules; the
    # npmConfigHook expects the lockfile at npmRoot.
    npmDeps = importNpmLock.buildNodeModules {
      npmRoot = source.src + "/ping";
      inherit nodejs;
    };
    npmRoot = "ping";

    # Runtime-only tree (chokidar + zod, no devDependencies): tsc and eslint
    # never ship in $out, so the closure stays free of their native binaries
    # (lightningcss, rolldown) that ride along with the full dev install above.
    runtimeNpmDeps = importNpmLock.buildNodeModules {
      npmRoot = source.src + "/ping";
      inherit nodejs;
      derivationArgs.npmInstallFlags = "--omit=dev";
    };

    # engines pins an exact Node (24.13.0); nixpkgs ships 24.19.0 (same major).
    npm_config_engine_strict = "false";

    buildPhase = ''
      runHook preBuild
      cd ping
      npm run build
      cd ..
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r ping/dist $out/dist
      # Runtime deps live beside dist/ so Node's module resolution finds them
      # walking up from dist/ping/src/*.js (chokidar + zod only, no devDeps).
      cp -r ${finalAttrs.runtimeNpmDeps}/node_modules $out/dist/node_modules
      # tsc emits dist/ping/src/app.js (rootDir spans repo for shared imports).
      entry="$out/dist/ping/src/app.js"
      if [ ! -f "$entry" ]; then
        entry="$(find $out/dist -name app.js -path '*ping*' | head -n1)"
      fi
      makeWrapper ${nodejs}/bin/node $out/bin/picr-ping \
        --add-flags "$entry"
      runHook postInstall
    '';

    passthru.nodejs = nodejs;

    meta = {
      description = "PICR Ping: media-change hint sidecar for a PICR server";
      homepage = "https://github.com/isaacinsoll/picr";
      license = lib.licenses.isc;
      mainProgram = "picr-ping";
      platforms = ["x86_64-linux" "aarch64-linux"];
    };
  })
