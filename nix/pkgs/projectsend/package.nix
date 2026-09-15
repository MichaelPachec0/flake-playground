# ProjectSend: prebuilt Laravel app from the upstream release .zip.
#
# The zip bundles vendor/ (composer deps) and public/build/ (Vite assets), so
# there is no composer or npm build here. This derivation unpacks it, adjusts
# the private-file permission modes so a separate nginx user can read protected
# downloads via a shared group (see the filesystems.php substitution below),
# points the artisan shebang at the store PHP, and relocates every writable
# path (storage/, bootstrap/cache, .env, public/storage) to the runtime state
# directory via symlinks -- the store copy stays read-only.
{
  lib,
  stdenvNoCC,
  unzip,
  php84,
  source,
  # The runtime state directory the module uses (systemd StateDirectory).
  # Baked into the symlinks; keep in step with the module's readOnly dataDir.
  stateDir ? "/var/lib/projectsend",
  # Whether the bundled PHP includes the redis (phpredis) extension. The
  # module always uses the default (true): phpredis is bundled regardless of
  # services.projectsend.redis.enable.
  withRedis ? true,
}: let
  php = php84.withExtensions ({
    enabled,
    all,
  }:
    (with all; [
      bcmath
      ctype
      curl
      dom
      fileinfo
      filter
      gd
      iconv
      intl
      ldap
      mbstring
      openssl
      pcntl
      pdo_mysql
      session
      simplexml
      tokenizer
      zip
      opcache
    ])
    ++ lib.optional withRedis all.redis);
in
  stdenvNoCC.mkDerivation {
    pname = "projectsend";
    inherit (source) version;
    src = source.src;

    nativeBuildInputs = [unzip];

    # The .zip has files at the top level (no single wrapping directory).
    sourceRoot = ".";

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp -r . "$out/"

      # Group-readable private modes so nginx (in the projectsend group) can
      # stream protected downloads without world-readable files. The upstream
      # config exposes only the world-readable FILES_WEB_SERVER_READABLE
      # branch via env; this inserts a static private-mode block before it.
      # directory_visibility=private makes Flysystem read dir.private (0750).
      substituteInPlace "$out/config/filesystems.php" \
        --replace-fail "            ...(env('FILES_WEB_SERVER_READABLE', false)" \
        "            'directory_visibility' => 'private',
            'permissions' => [
                'file' => ['public' => 0644, 'private' => 0640],
                'dir' => ['public' => 0755, 'private' => 0750],
            ],
            ...(env('FILES_WEB_SERVER_READABLE', false)"

      # artisan runs as a CLI script; point its shebang at the store PHP.
      patchShebangs "$out/artisan"
      substituteInPlace "$out/artisan" \
        --replace-quiet "#!/usr/bin/env php" "#!${php}/bin/php" || true

      # Relocate every writable path to the runtime state directory. The store
      # copy is read-only; these symlinks resolve into ${stateDir}, which the
      # module's StateDirectory + tmpfiles create and own.
      rm -rf "$out/storage" "$out/bootstrap/cache"
      ln -s "${stateDir}/storage" "$out/storage"
      ln -s "${stateDir}/bootstrap-cache" "$out/bootstrap/cache"
      ln -s "${stateDir}/.env" "$out/.env"
      # storage:link (run by projectsend:update) would try to create this under
      # the read-only store and fail; bake the correct link so it no-ops.
      ln -s "${stateDir}/storage/app/public" "$out/public/storage"

      runHook postInstall
    '';

    passthru = {inherit php;};

    meta = {
      description = "ProjectSend: client file sharing, self-hosted (Community edition)";
      homepage = "https://www.projectsend.org/";
      license = lib.licenses.gpl2Plus;
      platforms = lib.platforms.linux;
    };
  }
