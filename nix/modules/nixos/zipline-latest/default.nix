# NixOS module for zipline-latest: Zipline at its latest upstream stable
# release (nix/pkgs/zipline), next to (not replacing) nixpkgs services.zipline.
#
# Databases: PostgreSQL (default; local server via database.createLocally) or
# PGlite (embedded, `pglite:///var/lib/zipline-latest/db`, no server).
#
# Upgrading a 4.7.0 PostgreSQL database to 4.8.0+: upstream refuses on its own
# unless EXACTLY the 4.7.0 Prisma migration set is applied (checked with
# checksums inside one transaction; on mismatch it rolls back, records nothing
# and the unit fails with "cannot safely migrate from prisma to drizzle").
# Before that, this module's pre-start check logs the follow-up steps and, with
# backupBeforeAdoption, pg_dumps to /var/lib/zipline-latest/backups.
#
# Follow-up steps after 4.8.0 that cannot be inferred:
#   * behind a reverse proxy, set trustedProxies (CORE_TRUST_PROXY alone is
#     ignored since 4.8.0);
#   * custom uploaders must switch partialIdentifier / x-zipline-p-identifier
#     to partialToken / x-zipline-p-token;
#   * keep the same CORE_SECRET when moving an install: API tokens handed to
#     uploaders are encrypted with it.
#
# Moving from nixpkgs services.zipline by hand: stop it on 4.7.0, pg_dump the
# `zipline` DB and pg_restore it into `zipline-latest` (or point
# settings.DATABASE_URL at the old DB with database.createLocally = false),
# copy /var/lib/private/zipline/uploads to /var/lib/private/zipline-latest/uploads,
# then enable this module. experimental.importFromNixpkgs automates exactly
# that; experimental.migrateToPglite automates upstream's
# `ziplinectl migrate-pglite` cutover. Both are experimental.
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.zipline-latest;
  name = "zipline-latest";
  # What the app sees (systemd symlink) vs. the real path behind DynamicUser.
  stateDir = "/var/lib/${name}";
  privateDir = "/var/lib/private/${name}";
  localPgUrl = "postgresql://${name}@localhost/${name}?host=/run/postgresql";
  pgPackage = config.services.postgresql.package;
  isPglite = cfg.database.type == "pglite";
  usesPostgres = cfg.database.createLocally;

  hardening = {
    AmbientCapabilities = "";
    CapabilityBoundingSet = [""];
    DevicePolicy = "closed";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProcSubset = "pid";
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RemoveIPC = true;
    RestrictAddressFamilies = ["AF_INET AF_INET6 AF_UNIX AF_NETLINK"];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = ["@system-service" "~@privileged" "~@resources" "@chown"];
    UMask = "0077";
  };

  # Shared by the main unit and the PGlite cutover unit: same user name means
  # the same dynamic UID, so files either one writes are owned by the server.
  serviceIdentity = {
    User = name;
    Group = name;
    DynamicUser = true;
    StateDirectory = name;
    EnvironmentFile = cfg.environmentFiles;
  };
  serviceEnvironment = lib.mapAttrs (_: toString) cfg.settings;

  # Runs as the service user before every start (postgresql only). Detects the
  # one start that will adopt a 4.7.0 Prisma database (Prisma history present,
  # Drizzle history absent), logs the follow-up steps and optionally pg_dumps.
  # It never judges the Prisma history itself: upstream does that right after,
  # transactionally, against its own checksum list.
  adoptionCheck = pkgs.writeShellApplication {
    name = "${name}-adoption-check";
    runtimeInputs = [pgPackage pkgs.coreutils];
    text = ''
      if [ -z "''${DATABASE_URL:-}" ]; then
        echo "<4>${name}: DATABASE_URL unset (DATABASE_* variables?); skipping the adoption pre-check"
        exit 0
      fi
      case "$DATABASE_URL" in pglite:*) exit 0 ;; esac

      q() { psql "$DATABASE_URL" -XAtq -c "$1"; }

      [ "$(q "SELECT to_regclass('public._prisma_migrations') IS NOT NULL")" = t ] || exit 0
      if [ "$(q "SELECT to_regclass('drizzle.__drizzle_migrations') IS NOT NULL")" = t ] &&
        [ "$(q 'SELECT count(*) > 0 FROM drizzle.__drizzle_migrations')" = t ]; then
        exit 0
      fi

      while IFS= read -r line; do echo "<4>$line"; done <<'EOF'
      ${name}: this start will adopt a Zipline 4.7 database (Prisma -> Drizzle).
      Upstream refuses unless the database is exactly on 4.7.0; nothing is changed if it refuses.
      Follow-up steps after 4.8.0:
        - behind a reverse proxy: set services.${name}.trustedProxies (CORE_TRUST_PROXY alone is ignored)
        - custom uploaders: partialIdentifier / x-zipline-p-identifier -> partialToken / x-zipline-p-token
        - keep the same CORE_SECRET as the old install
      Release notes: https://github.com/diced/zipline/releases/tag/v4.8.0
      EOF

      ${lib.optionalString cfg.backupBeforeAdoption ''
        install -d -m 0700 "$STATE_DIRECTORY/backups"
        out="$STATE_DIRECTORY/backups/pre-drizzle-$(date -u +%Y%m%dT%H%M%SZ).sql"
        pg_dump "$DATABASE_URL" --file="$out"
        echo "<5>${name}: backup written to $out"
      ''}
    '';
  };
in {
  options.services.zipline-latest = {
    enable = lib.mkEnableOption "Zipline (latest upstream stable release)";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.zipline-latest;
      defaultText = lib.literalExpression "inputs.self.packages.\${system}.zipline-latest";
      description = "The zipline-latest package to run.";
    };

    settings = lib.mkOption {
      description = ''
        Zipline environment configuration. See <https://zipline.diced.sh/docs/config>.
        Put secrets such as CORE_SECRET in environmentFiles instead.
      '';
      default = {};
      type = lib.types.submodule {
        freeformType = with lib.types; attrsOf (oneOf [str int]);
        options = {
          CORE_HOSTNAME = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Address to listen on.";
          };
          CORE_PORT = lib.mkOption {
            type = lib.types.port;
            default = 3000;
            description = "Port to listen on.";
          };
          CORE_TEMP_DIRECTORY = lib.mkOption {
            type = lib.types.path;
            defaultText = lib.literalExpression ''"''${settings.DATASOURCE_LOCAL_DIRECTORY}/.tmp"'';
            description = "Temporary directory for uploads in progress.";
          };
        };
      };
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      example = ["/run/secrets/zipline-latest.env"];
      description = "Environment files (secrets) loaded in addition to settings.";
    };

    database = {
      type = lib.mkOption {
        type = lib.types.enum ["postgresql" "pglite"];
        default = "postgresql";
        description = ''
          postgresql: a PostgreSQL server (local when createLocally).
          pglite: embedded PGlite at /var/lib/zipline-latest/db, no server.
        '';
      };
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = cfg.database.type == "postgresql" || cfg.experimental.migrateToPglite.enable;
        defaultText = lib.literalExpression ''database.type == "postgresql" || experimental.migrateToPglite.enable'';
        description = "Enable and configure a local PostgreSQL server and database.";
      };
    };

    trustedProxies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["127.0.0.1" "10.0.0.0/8"];
      description = ''
        Reverse proxy IPs/CIDRs whose forwarded headers are trusted. Non-empty
        sets CORE_TRUST_PROXY=true and CORE_TRUSTED_PROXIES. Empty: forwarded
        headers are ignored, so clients behind one proxy share rate limits.
      '';
    };

    backupBeforeAdoption = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        pg_dump to /var/lib/zipline-latest/backups/pre-drizzle-<ts>.sql before
        the first start adopts a 4.7.0 Prisma database. A dump failure fails
        the unit.
      '';
    };

    experimental = {
      importFromNixpkgs = {
        enable = lib.mkEnableOption ''
          a one-shot import of a nixpkgs services.zipline (4.7.0) install:
          database copy (pg_dump/pg_restore) and uploads copy, before the
          first start. EXPERIMENTAL
        '';
        sourceDatabase = lib.mkOption {
          type = lib.types.str;
          default = "zipline";
          description = "Source database name on the local PostgreSQL server.";
        };
        sourceUploadsDir = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/private/zipline/uploads";
          description = "Source uploads (real path behind the nixpkgs DynamicUser).";
        };
        copyUploads = lib.mkOption {
          type = lib.types.bool;
          default = (cfg.settings.DATASOURCE_TYPE or "local") == "local";
          defaultText = lib.literalExpression ''settings.DATASOURCE_TYPE == "local"'';
          description = "Copy local uploads (not needed for S3).";
        };
      };
      migrateToPglite = {
        enable = lib.mkEnableOption ''
          a one-shot PostgreSQL -> PGlite cutover with upstream
          `ziplinectl migrate-pglite`, before the first PGlite start.
          EXPERIMENTAL
        '';
        sourceDatabaseUrl = lib.mkOption {
          type = lib.types.str;
          default = localPgUrl;
          description = "PostgreSQL source; must already be adopted by 4.8.0+.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.zipline-latest.settings = lib.mkMerge [
      {
        DATASOURCE_TYPE = lib.mkDefault "local";
        DATASOURCE_LOCAL_DIRECTORY = lib.mkDefault "${stateDir}/uploads";
        CORE_TEMP_DIRECTORY = lib.mkDefault "${cfg.settings.DATASOURCE_LOCAL_DIRECTORY}/.tmp";
      }
      (lib.mkIf (!isPglite && usesPostgres) {DATABASE_URL = lib.mkDefault localPgUrl;})
      (lib.mkIf isPglite {DATABASE_URL = lib.mkDefault "pglite://${stateDir}/db";})
      (lib.mkIf (cfg.trustedProxies != []) {
        CORE_TRUST_PROXY = "true";
        CORE_TRUSTED_PROXIES = lib.concatStringsSep "," cfg.trustedProxies;
      })
    ];

    assertions = [
      {
        assertion = !(isPglite && cfg.database.createLocally && !cfg.experimental.migrateToPglite.enable);
        message = "services.zipline-latest: database.type = \"pglite\" needs no local PostgreSQL; set database.createLocally = false (it stays allowed only with experimental.migrateToPglite).";
      }
      {
        assertion = !isPglite || lib.hasPrefix "pglite:///" (cfg.settings.DATABASE_URL or "");
        message = "services.zipline-latest: database.type = \"pglite\" requires settings.DATABASE_URL = \"pglite:///<absolute path>\".";
      }
      {
        assertion = !(config.services.zipline.enable && cfg.settings ? DATABASE_URL && config.services.zipline.settings ? DATABASE_URL && config.services.zipline.settings.DATABASE_URL == cfg.settings.DATABASE_URL);
        message = "services.zipline-latest: nixpkgs services.zipline uses the same DATABASE_URL; a 4.7 server on a Drizzle-adopted database corrupts it.";
      }
      {
        assertion = !cfg.experimental.importFromNixpkgs.enable || (!config.services.zipline.enable && cfg.database.type == "postgresql");
        message = "services.zipline-latest: experimental.importFromNixpkgs requires services.zipline.enable = false and database.type = \"postgresql\".";
      }
      {
        assertion = !cfg.experimental.migrateToPglite.enable || isPglite;
        message = "services.zipline-latest: experimental.migrateToPglite requires database.type = \"pglite\".";
      }
    ];

    warnings =
      lib.optional ((cfg.settings ? CORE_TRUST_PROXY) && cfg.trustedProxies == [] && !(cfg.settings ? CORE_TRUSTED_PROXIES))
      "services.zipline-latest: CORE_TRUST_PROXY is set but trustedProxies is empty; since 4.8.0 forwarded headers are ignored, so all clients behind the proxy share rate limits."
      ++ lib.optional cfg.experimental.importFromNixpkgs.enable
      "services.zipline-latest: experimental.importFromNixpkgs is EXPERIMENTAL; read the module header before relying on it. It runs once (marker ${privateDir}/.imported-from-nixpkgs) and can be removed afterwards."
      ++ lib.optional cfg.experimental.migrateToPglite.enable
      "services.zipline-latest: experimental.migrateToPglite is EXPERIMENTAL; read the module header before relying on it. Writes made on PGlite are never copied back to PostgreSQL.";

    services.postgresql = lib.mkIf usesPostgres {
      enable = true;
      ensureUsers = lib.singleton {
        inherit name;
        ensureDBOwnership = true;
      };
      ensureDatabases = [name];
    };

    systemd.services.${name} = {
      description = "Zipline (latest stable)";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"] ++ lib.optional usesPostgres "postgresql.target";
      requires = lib.optional (usesPostgres && !isPglite) "postgresql.target";
      environment = serviceEnvironment;
      serviceConfig =
        hardening
        // serviceIdentity
        // {
          ExecStartPre = lib.optional (!isPglite) (lib.getExe adoptionCheck);
          ExecStart = lib.getExe cfg.package;
        };
    };
  };
}
