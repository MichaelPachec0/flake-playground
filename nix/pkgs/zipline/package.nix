# Zipline built from source at the nvfetcher-pinned release.
#
# Adapted from nixpkgs pkgs/by-name/zi/zipline/package.nix (4.7.0). Changes for
# 4.8.0+: Prisma was replaced by Drizzle, so there are no prisma-engines and the
# `drizzle/` migrations folder ships instead of `prisma/` (the server reads it
# from `$cwd/drizzle` at startup, hence --chdir in the wrappers). Upstream pins
# pnpm 11 in package.json `packageManager`, so this uses pnpm_11.
#
# The pnpm deps hash is read from ./pnpm-deps.hash. nvfetcher cannot compute it;
# CI recomputes it with scripts/heal-pnpm-hash.sh on every bump.
{
  lib,
  stdenv,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
  nodejs_24,
  makeWrapper,
  ffmpeg,
  openssl,
  vips,
  versionCheckHook,
  node-gyp,
  pkg-config,
  python3,
  source,
}: let
  environment = {
    FFMPEG_PATH = lib.getExe ffmpeg;
    FFPROBE_PATH = lib.getExe' ffmpeg "ffprobe";
  };

  pnpm' = pnpm_11.override {nodejs-slim = nodejs_24;};
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "zipline-latest";
    version = lib.removePrefix "v" source.version;
    inherit (source) src;

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pnpm';
      fetcherVersion = 4;
      hash = lib.fileContents ./pnpm-deps.hash;
    };

    buildInputs = [openssl vips];

    nativeBuildInputs = [
      pnpmConfigHook
      pnpm'
      nodejs_24
      makeWrapper
      # sharp is rebuilt against the system libvips (old CPUs without SSE 4.2)
      node-gyp
      pkg-config
      python3
    ];

    env =
      environment
      // {
        # Upstream's build switch: skips config validation and DB connection
        # at import time (the Dockerfile sets it for `pnpm run build`).
        ZIPLINE_BUILD = "true";
        NODE_PATH = "${node-gyp}/lib/node_modules";
        # pnpm 11 rejects `pnpm config set nodedir`; node-gyp reads this instead.
        npm_config_nodedir = nodejs_24;
      };

    buildPhase = ''
      runHook preBuild

      npm explore sharp -- pnpm run build

      # `pnpm build` also runs oxfmt, oxlint and tsc (TypeScript 7 ships as a
      # prebuilt native binary). None of them produce build output, so run
      # only the steps that do, by name (scripts/build.ts accepts one step).
      pnpm build build/server
      pnpm build build/client
      pnpm build build/client/ssr/view
      pnpm build build/client/ssr/view-url

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      CI=true pnpm prune --prod
      find node_modules -xtype l -delete

      mkdir -p $out/{bin,share/zipline}
      cp -r build node_modules drizzle mimes.json code.json package.json $out/share/zipline

      mkBin() {
        makeWrapper ${lib.getExe nodejs_24} "$out/bin/$1" \
          --chdir "$out/share/zipline" \
          --set NODE_ENV production \
          --set ZIPLINE_ROOT "$out/share/zipline" \
          --set ZIPLINE_GIT_SHA ${lib.escapeShellArg source.version} \
          --prefix PATH : ${lib.makeBinPath [openssl]} \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [openssl]} \
          ${lib.concatStringsSep " " (lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") environment)} \
          --add-flags "--enable-source-maps build/$2"
      }

      mkBin zipline server
      mkBin ziplinectl ctl

      runHook postInstall
    '';

    nativeInstallCheckInputs = [versionCheckHook];
    versionCheckProgram = "${placeholder "out"}/bin/ziplinectl";
    doInstallCheck = true;

    passthru.nodejs = nodejs_24;

    meta = {
      description = "ShareX/file upload server, tracked at the latest upstream stable release";
      homepage = "https://zipline.diced.sh/";
      downloadPage = "https://github.com/diced/zipline";
      changelog = "https://github.com/diced/zipline/releases/tag/${source.version}";
      license = lib.licenses.mit;
      mainProgram = "zipline";
      platforms = lib.platforms.linux;
    };
  })
