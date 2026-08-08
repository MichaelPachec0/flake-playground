# AFFiNE self-host server, packaged Path B: extract the built /app tree from the
# upstream OCI image (nvfetcher-pinned by digest), autoPatchelf the prebuilt
# native .node addons + Prisma engine for NixOS, and run it natively under node.
# No container runtime. The NixOS module (services.affine) consumes:
#   $out/app/dist/main.js               (server entry)
#   $out/app/scripts/self-host-predeploy.js (migration entry)
#   passthru.nodejs                     (the exact Node the addons were built for)
# A future from-source build (Path A) can replace this file's internals while
# keeping the same output contract. See spec section 3 / section 5.
{
  lib,
  stdenv,
  runCommand,
  jq,
  gnutar,
  autoPatchelfHook,
  makeWrapper,
  nodejs_22,
  openssl,
  source,
}: let
  # Fixed pname: the aarch64 build is fed the `affine-server-arm64` nvfetcher
  # source (different digest/arch), but the package is the same thing; don't let
  # the source's name leak into the derivation name.
  pname = "affine-server";
  inherit (source) version src;

  # Flatten the docker-archive into a single rootfs. Observed layout of this
  # image (docker save / dockerTools.pullImage): manifest.json's `.[0].Layers`
  # lists top-level `<sha>.tar` entries sitting at the archive root (the archive
  # also carries legacy `<sha>/layer.tar` dirs, which we ignore; we follow the
  # manifest). Untar the image, then untar each referenced layer in manifest
  # order (later layers win) into $out. `|| true` tolerates overlay whiteout
  # quirks that make tar exit non-zero on otherwise-fine layers.
  rootfs = runCommand "${pname}-rootfs" {nativeBuildInputs = [jq gnutar];} ''
    mkdir image && tar -xf ${src} -C image
    mkdir -p $out
    for layer in $(jq -r '.[0].Layers[]' image/manifest.json); do
      tar -xf "image/$layer" -C $out || true
    done
  '';
in
  stdenv.mkDerivation {
    inherit pname version;
    dontUnpack = true;

    # The upstream image ships three vestigial pnpm workspace symlinks
    # (@affine/server, @affine/server-native, @affine/s3-compat) that dangle
    # even in the original container: their `packages/...` targets are not in
    # the runtime image (the server runs from the bundled dist/main.js). Docker
    # ignores dangling symlinks; nixpkgs' noBrokenSymlinks fixup fails the build
    # on them. Opt out to preserve the image tree exactly rather than mutate it.
    dontCheckForBrokenSymlinks = true;

    nativeBuildInputs = [autoPatchelfHook makeWrapper];
    # Covers every DT_NEEDED across the prebuilt ELFs (server-native, Prisma
    # query+schema engines, @node-rs/@napi-rs/msgpackr addons): stdenv.cc.cc.lib
    # -> libstdc++/libgcc_s, openssl -> libssl/libcrypto, glibc (autoPatchelf
    # default) -> libc/libm/libpthread/librt/libdl + the ELF interpreter.
    buildInputs = [stdenv.cc.cc.lib openssl nodejs_22];

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a ${rootfs}/app $out/app
      chmod -R u+w $out/app

      # msgpackr ships both glibc and musl prebuilt addons; the musl `*.node`
      # variants need musl's unversioned `libc.so`, which this glibc system does
      # not provide, and detect-libc never selects them on glibc anyway. Drop
      # them so autoPatchelf's "no unresolved lib" gate stays meaningful rather
      # than being papered over with an ignore.
      find $out/app -name '*.musl.node' -delete

      # NestJS regenerates the GraphQL schema to <projectRoot>/src/schema.gql on
      # every start (projectRoot is import.meta.url-derived, so it always points at
      # this read-only bundle). Ship an empty app/src so a runtime tmpfs can be
      # bind-mounted over it (the consuming module does this) -- systemd can't create
      # the mountpoint itself under the read-only store.
      mkdir -p $out/app/src

      # Pin the Prisma library query engine (a .node addon) for the wrapped
      # process. Only add the flag if an engine is actually present, so the
      # wrapper stays correct if a future image relocates or drops it.
      prismaFlags=()
      prismaEngine="$(find $out/app -name 'libquery_engine*.node' -type f | head -n1)"
      if [ -n "$prismaEngine" ]; then
        prismaFlags=(--set-default PRISMA_QUERY_ENGINE_LIBRARY "$prismaEngine")
      fi

      # Launcher: run the server with the pinned node, from /app.
      makeWrapper ${nodejs_22}/bin/node $out/bin/affine-server \
        --add-flags "$out/app/dist/main.js" \
        --chdir $out/app \
        "''${prismaFlags[@]}"
      runHook postInstall
    '';

    # autoPatchelfHook scans $out for ELF files (.node addons, prisma engines)
    # and rewrites their interpreter/rpath. It FAILS the build on any unresolved
    # lib, which is our correctness gate for the patch step.
    passthru.nodejs = nodejs_22;

    meta = {
      description = "Self-hosted AFFiNE server (patched from the upstream OCI image)";
      homepage = "https://affine.pro";
      mainProgram = "affine-server";
      platforms = ["x86_64-linux" "aarch64-linux"];
      # AFFiNE's server is NOT MIT. It is a mash: an MIT core plus portions
      # (collaboration/enterprise features, etc.) under AFFiNE's own custom,
      # non-free terms. This Path-B build ships the whole prebuilt image, which
      # INCLUDES the non-MIT code, so the package is UNFREE. (nixpkgs' `affine`
      # desktop is labelled MIT, but the self-host server bundle is a different
      # licensing story, so don't infer one from the other.)
      #
      # TODO(license, post-v1): split into two packages behind the same output
      # contract:
      #   * affine-server     : build from source with the non-MIT code stripped
      #                         out, so it is genuinely free (MIT), free = true.
      #   * affine-server-bin : the full prebuilt image (this build), everything
      #                         included, free = false, plus a build-time warning
      #                         that surfaces the AFFiNE license terms to the user.
      license = {
        shortName = "affine";
        fullName = "AFFiNE license (MIT core + custom non-free portions)";
        url = "https://github.com/toeverything/AFFiNE/blob/canary/LICENSE";
        free = false;
      };
    };
  }
