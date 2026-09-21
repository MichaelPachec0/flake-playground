# pingvin-share-x, built from source (Path A). Upstream Docker image is
# node:24-alpine (musl); patching onto glibc (affine Path B) would drag a
# musl runtime in. Build with buildNpmPackage instead. One function serves
# both channels: `source` is an nvfetcher entry, stable or beta.
#
# Output contract read by the NixOS module (nix/modules/nixos/pingvin-share):
#   $out/backend/{dist,node_modules,prisma,package.json}
#   $out/frontend/{server.js,.next/static,public}   (Next standalone layout)
#   passthru.nodejs         -- exact node used to build the addons
#   passthru.prismaEngines  -- patched engines for the module's runtime env
{
  lib,
  stdenv,
  buildNpmPackage,
  nodejs_24,
  python3,
  autoPatchelfHook,
  vips,
  pkg-config,
  openssl,
  callPackage,
  fetchurl,
  node-gyp,
  source,
  # Defaults are the stable channel's npmDepsHash. Beta has different
  # package-lock files (different deps); callers building beta must
  # override both.
  backendNpmDepsHash ? "sha256-waAY3mN5QZfJwqN3+ukjeaQhQDRLBwalwrsQacuIRcA=",
  frontendNpmDepsHash ? "sha256-S20834EftT5we8ugTW9P16G3s8JtaqcZdhvgPoReheQ=",
}: let
  nodejs = nodejs_24;
  version = lib.removePrefix "v" source.version;
  src = source.src;

  prismaEngines = callPackage ./pingvin-share-prisma-engines.nix {};

  # Point Prisma at the patched engines; block its download attempt (sandbox
  # has no network, store is read-only anyway). Used at BUILD time (prisma
  # generate); the module mirrors this at RUNTIME.
  prismaEnv = ''
    export PRISMA_QUERY_ENGINE_LIBRARY=${prismaEngines}/lib/libquery_engine.so.node
    export PRISMA_SCHEMA_ENGINE_BINARY=${prismaEngines}/bin/schema-engine
    export PRISMA_CLI_QUERY_ENGINE_TYPE=library
    export PRISMA_ENGINES_MIRROR=file:///dev/null
    export CHECKPOINT_DISABLE=1
    export PRISMA_GENERATE_SKIP_AUTOINSTALL=true
  '';

  # sharp ships a prebuilt
  # @img/sharp-libvips-linux-x64/lib/libvips-cpp.so.8.18.6 with a broken
  # DT_INIT tag; dlopen() segfaults immediately (confirmed via
  # `node -e "require('sharp')"`, no NixOS/systemd/autoPatchelf involved -
  # the binary itself is corrupt).
  #
  # sharp's loader (dist/sharp.cjs) falls back to that broken prebuilt only
  # if no local addon exists at
  # src/build/Release/sharp-<platform>-<version>.node. Build sharp from
  # source against nixpkgs' vips (already a buildInput, matches sharp
  # 0.35's minimum 8.18.6) to avoid the broken binary entirely.
  #
  # node-addon-api is sharp's own devDependency, not ours, so npm never
  # installs it; vendor it directly instead of hand-editing
  # package-lock.json (would need an npmDepsHash refresh). node-gyp is
  # supplied as a plain CLI via nativeBuildInputs rather than through
  # sharp's install/build.js (which needs node-gyp require()-able from
  # node_modules, not just on PATH); drive `node-gyp rebuild` directly.
  nodeAddonApi = fetchurl {
    url = "https://registry.npmjs.org/node-addon-api/-/node-addon-api-8.9.2.tgz";
    hash = "sha512-VijLXbi3UACN69I0JVXJsX4tjACjNoQDgv2gTF6sx2wWEi8tkSg2eX8p5gSIFi8z2+DL3oHmY6OyKce38SDolg==";
  };

  # Run from the package root (cwd with node_modules/), after npm
  # ci/rebuild populate node_modules (npmConfigHook, postPatch) but before
  # `npm run build`. Produces
  # node_modules/sharp/src/build/Release/sharp-linux-x64-<version>.node,
  # linked against nixpkgs' libvips-cpp.so; autoPatchelfHook (fixupPhase)
  # gives it an RPATH like every other native addon here.
  rebuildSharpFromSource = ''
    mkdir -p node_modules/node-addon-api
    tar -xzf ${nodeAddonApi} -C node_modules/node-addon-api --strip-components=1
    SHARP_FORCE_GLOBAL_LIBVIPS=1 node-gyp rebuild --directory=node_modules/sharp/src --nodedir=${nodejs}
  '';

  backend = buildNpmPackage {
    pname = "pingvin-share-backend";
    inherit version src;
    sourceRoot = "${src.name}/backend";

    npmDepsHash = backendNpmDepsHash;

    nativeBuildInputs = [
      python3 # node-gyp needs this to build argon2
      pkg-config
      node-gyp # rebuilds sharp from source against nixpkgs' vips; see rebuildSharpFromSource
      autoPatchelfHook # patches argon2.node and the freshly built sharp.node
      nodejs
    ];
    buildInputs = [vips openssl stdenv.cc.cc.lib];

    # npm installs both glibc and musl prebuilt addon variants for argon2
    # and sharp (argon2 ships prebuilds/linux-x64/argon2.musl.node; sharp's
    # musl optionalDependencies land too). NixOS uses only the glibc
    # variants; the musl siblings are dead weight autoPatchelfHook would
    # otherwise hard-fail on.
    autoPatchelfIgnoreMissingDeps = ["libc.musl-x86_64.so.1"];

    # argon2 compiles via node-gyp; sharp is rebuilt from source below
    # instead of using its broken prebuilt. Keep install scripts (no
    # --ignore-scripts).
    preBuild =
      prismaEnv
      + ''
        npx prisma generate
      ''
      + rebuildSharpFromSource;

    buildPhase = ''
      runHook preBuild
      npm run build
      # Compile DB config seed to JS (matches upstream Dockerfile).
      npx tsc prisma/seed/config.seed.ts \
        --outDir dist/prisma/seed --rootDir prisma/seed
      npm prune --omit=dev
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/backend
      cp -r dist node_modules prisma package.json $out/backend/
      runHook postInstall
    '';

    # buildNpmPackage's default npm-pack install expects a publishable
    # package; we ship a server tree instead, so install manually above.
    dontNpmInstall = true;

    passthru = {inherit nodejs prismaEngines;};
  };

  frontend = buildNpmPackage {
    pname = "pingvin-share-frontend";
    inherit version src;
    sourceRoot = "${src.name}/frontend";

    npmDepsHash = frontendNpmDepsHash;

    # Next.js's image optimizer also pulls in sharp with the same broken
    # vendored libvips-cpp.so (see rebuildSharpFromSource above); rebuild
    # from source here too.
    nativeBuildInputs = [nodejs python3 pkg-config node-gyp autoPatchelfHook];
    buildInputs = [vips];
    autoPatchelfIgnoreMissingDeps = ["libc.musl-x86_64.so.1"];

    env.NEXT_TELEMETRY_DISABLED = "1";

    preBuild = rebuildSharpFromSource;

    buildPhase = ''
      runHook preBuild
      npm run build
      runHook postBuild
    '';

    # Next standalone layout: server.js + minimal node_modules under
    # .next/standalone, static files under .next/static, plus public/.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/frontend
      cp -r .next/standalone/. $out/frontend/
      mkdir -p $out/frontend/.next
      cp -r .next/static $out/frontend/.next/static
      cp -r public $out/frontend/public
      runHook postInstall
    '';

    dontNpmInstall = true;
  };
in
  stdenv.mkDerivation {
    pname = "pingvin-share-x";
    inherit version;
    dontUnpack = true;

    nativeBuildInputs = [nodejs]; # makeWrapper-free; plain shell script below

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp -r ${backend}/backend $out/backend
      cp -r ${frontend}/frontend $out/frontend
      chmod -R u+w $out/backend $out/frontend

      cat > $out/bin/pingvin-share-backend <<EOF
      #!${stdenv.shell}
      export NODE_ENV=production
      export PRISMA_QUERY_ENGINE_LIBRARY=${prismaEngines}/lib/libquery_engine.so.node
      export PRISMA_SCHEMA_ENGINE_BINARY=${prismaEngines}/bin/schema-engine
      cd $out/backend
      exec ${nodejs}/bin/node dist/src/main "\$@"
      EOF

      cat > $out/bin/pingvin-share-frontend <<EOF
      #!${stdenv.shell}
      cd $out/frontend
      exec ${nodejs}/bin/node server.js "\$@"
      EOF

      chmod +x $out/bin/pingvin-share-backend $out/bin/pingvin-share-frontend
      runHook postInstall
    '';

    passthru = {inherit nodejs prismaEngines;};

    meta = {
      description = "Self-hosted file sharing (pingvin-share-x fork), built from source";
      homepage = "https://github.com/smp46/pingvin-share-x";
      license = lib.licenses.bsd2;
      platforms = ["x86_64-linux" "aarch64-linux"];
      mainProgram = "pingvin-share-backend";
    };
  }
