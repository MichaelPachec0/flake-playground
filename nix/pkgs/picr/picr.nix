# PICR server, built from source. The upstream OCI image is Alpine/musl, so we
# build against nixpkgs glibc from the repo tree instead of extracting it.
# Reproduces `build:local`: shared/backend/frontend installs via importNpmLock,
# backend tsc build, copy-backend-files.sh, dist runtime deps (dev-pruned), and
# the frontend vite build into dist/public.
#
# Sharp resolution (Task 3 Step 1 SPIKE outcome): APPROACH B won, and crucially
# the prebuilt binaries are shipped UNMODIFIED (no autoPatchelfHook).
# importNpmLock stages the prebuilt glibc @img/sharp-linux-x64 +
# @img/sharp-libvips-linux-x64 packages straight from the lockfile and never
# runs Sharp's install script, so there is no from-source build to redirect
# (SHARP_IGNORE_GLOBAL_LIBVIPS only affects that build and is a no-op here).
#
# We do NOT patchelf these binaries. Two things were tried and rejected:
#   - Approach A (system nixpkgs vips): needs a from-source Sharp build that
#     importNpmLock does not run, and the prebuilt .node hard-links a versioned
#     libvips-cpp.so.8.18.3 soname that nixpkgs vips does not provide anyway.
#   - autoPatchelfHook on the prebuilt: it rewrites the 18 MB libvips-cpp.so and
#     corrupts it, so `require('sharp')` dies with SIGSEGV (SEGV_ACCERR) during
#     libvips static init. Verified: the unmodified prebuilt loads cleanly under
#     this exact nodejs, the patchelf'd one segfaults.
# The prebuilt is already NixOS-ready as shipped: its .node finds the bundled
# libvips through an $ORIGIN-relative RPATH, and its remaining NEEDED libs
# (libstdc++, libgcc_s, libc, ...) are satisfied at runtime by the copies nodejs
# has already loaded into the process (the wrapper always runs ${nodejs}/bin/node,
# whose closure carries a matching libstdc++/glibc). dontStrip + dontPatchELF keep
# the prebuilt byte-for-byte; both stripping and the default RPATH shrink are
# other ways to break it.
#
# Output contract consumed by the services.picr module (Task 4):
#   $out/dist/server/backend/app.js   server entry (run with cwd = state dir)
#   $out/dist/public                  built frontend (served static)
#   $out/dist/backend/db/drizzle      migrations (run in-process at boot)
#   $out/dist/node_modules            runtime deps incl. Sharp (dev-pruned)
#   $out/dist/version.txt, package.json
{
  lib,
  stdenv,
  importNpmLock,
  nodejs_24,
  ffmpeg,
  exiftool,
  imagemagick,
  makeWrapper,
  source,
}: let
  nodejs = nodejs_24;
  # Each workspace has its own committed lockfile; dist/ is generated at build
  # time from backend/package*.json (dist is gitignored), so its runtime deps
  # are the backend deps with dev pruned.
  sharedModules = importNpmLock.buildNodeModules {
    npmRoot = source.src + "/shared";
    inherit nodejs;
  };
  backendModules = importNpmLock.buildNodeModules {
    npmRoot = source.src + "/backend";
    inherit nodejs;
  };
  frontendModules = importNpmLock.buildNodeModules {
    npmRoot = source.src + "/frontend";
    inherit nodejs;
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "picr";
    inherit (source) version;
    src = source.src;

    nativeBuildInputs = [nodejs makeWrapper];

    npm_config_engine_strict = "false";

    dontConfigure = true;
    # Ship Sharp's prebuilt .node + libvips unmodified (see the Sharp note).
    # dontStrip: stripping corrupts the prebuilt libvips. dontPatchELF: skip the
    # default fixup RPATH shrink so the prebuilt's $ORIGIN RPATH (which locates
    # the bundled libvips) is left exactly as shipped.
    dontStrip = true;
    dontPatchELF = true;

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR

      # Stage per-workspace node_modules (writable copies so lifecycle/build
      # tooling can touch them).
      cp -r ${sharedModules}/node_modules shared/node_modules
      cp -r ${backendModules}/node_modules backend/node_modules
      cp -r ${frontendModules}/node_modules frontend/node_modules
      chmod -R u+w shared/node_modules backend/node_modules frontend/node_modules

      # 1. Backend build: tsc + tsc-alias -> dist/server, then copy migrations,
      #    package*.json, version.txt into dist/ (copy-backend-files.sh).
      ( cd backend && npm run build )

      # 2. dist runtime deps: dist/package.json now exists (a copy of backend's).
      #    Reuse backend's already-built node_modules (Sharp prebuilt above),
      #    then prune dev deps offline so the closure stays lean.
      cp -r backend/node_modules dist/node_modules
      chmod -R u+w dist/node_modules
      ( cd dist && npm prune --omit=dev --no-audit --offline )

      # importNpmLock stages every platform's optional Sharp prebuilt from the
      # lockfile. Only the current glibc-linux pair is ever loaded here; the
      # musl/darwin/win32/wasm variants are dead weight in the closure. Keep only
      # the native glibc pair (+ the @img/colour JS helper).
      arch=$(node -e 'process.stdout.write(process.arch)')
      find dist/node_modules/@img -mindepth 1 -maxdepth 1 -type d \
        ! -name colour \
        ! -name "sharp-linux-$arch" \
        ! -name "sharp-libvips-linux-$arch" \
        -exec rm -rf {} +

      # 3. Frontend build (vite) -> dist/public (outDir ../dist/public).
      ( cd frontend && npm run build )

      runHook postBuild
    '';

    # Correctness gate: dropping autoPatchelfHook also dropped its "fail on
    # unresolved lib" check, so nothing else proves Sharp's prebuilt actually
    # loads. Load it here under the pinned nodejs (dist/ exists in the build cwd
    # at check time, before install) so a future nixpkgs bump that breaks the
    # prebuilt's glibc/libstdc++ ABI FAILS the build instead of shipping a
    # segfaulting closure.
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      ${nodejs}/bin/node -e "require('$PWD/dist/node_modules/sharp'); console.log('sharp loads')"
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist $out/dist
      chmod -R u+w $out/dist

      # ffmpeg required (fatal boot check needs ffmpeg + ffprobe); exiftool +
      # imagemagick optional. All on PATH so the app finds them without
      # FFMPEG_PATH/etc.
      makeWrapper ${nodejs}/bin/node $out/bin/picr \
        --add-flags "$out/dist/server/backend/app.js" \
        --prefix PATH : ${lib.makeBinPath [ffmpeg exiftool imagemagick]}
      runHook postInstall
    '';

    passthru.nodejs = nodejs;

    meta = {
      description = "Self-hosted photo-sharing server (built from source)";
      homepage = "https://github.com/isaacinsoll/picr";
      license = lib.licenses.isc;
      mainProgram = "picr";
      platforms = ["x86_64-linux" "aarch64-linux"];
    };
  })
