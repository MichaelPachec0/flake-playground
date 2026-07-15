# NixOS module for a self-hosted AFFiNE server. flake-playground convention:
# `import ./affine inputs` -> a NixOS module. Runs the affine-server package
# (patched OCI image) natively under systemd with managed Postgres+Redis.
# See docs/superpowers/specs/2026-07-15-affine-server-nixos-module-design.md
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.affine;
  defaultUser = "affine";
  defaultGroup = "affine";
  stateDir = "/var/lib/affine";

  node = cfg.package.nodejs;
  appDir = "${cfg.package}/app";

  # Local peer auth => no password in the URL; the socket dir is the default.
  databaseUrl =
    if cfg.database.manage
    then "postgresql://${cfg.database.user}@/${cfg.database.name}?host=/run/postgresql"
    else "postgresql://${cfg.database.user}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}";

  commonEnv =
    {
      AFFINE_SERVER_HOST = cfg.host;
      AFFINE_SERVER_PORT = toString cfg.port;
      AFFINE_SERVER_EXTERNAL_URL = cfg.externalUrl;
      REDIS_SERVER_HOST = cfg.redis.host;
      REDIS_SERVER_PORT = toString cfg.redis.port;
      AFFINE_INDEXER_ENABLED = lib.boolToString cfg.indexer.enable;
      DATABASE_URL = databaseUrl;
      HOME = stateDir;
    }
    // cfg.extraEnvironment
    // storageEnv;

  # Credentials loaded by systemd (sops file paths) that the wrapper turns into
  # env at runtime, so no secret ever lands in the Nix store or static env.
  credentials =
    lib.optional (cfg.database.passwordFile != null) "db-password:${cfg.database.passwordFile}"
    ++ lib.optional (cfg.admin.passwordFile != null) "admin-password:${cfg.admin.passwordFile}"
    ++ lib.optional (cfg.storage.s3.accessKeyIdFile != null) "s3-access-key-id:${cfg.storage.s3.accessKeyIdFile}"
    ++ lib.optional (cfg.storage.s3.secretAccessKeyFile != null) "s3-secret-access-key:${cfg.storage.s3.secretAccessKeyFile}";

  # Build the env-composing prelude then exec node. Only assembles vars whose
  # secret files were provided.
  mkWrapped = entry:
    pkgs.writeShellScript "affine-${builtins.baseNameOf entry}" ''
      set -euo pipefail
      creds="''${CREDENTIALS_DIRECTORY:-}"
      ${lib.optionalString (!cfg.database.manage && cfg.database.passwordFile != null) ''
        # Percent-encode the password so reserved chars (@ : / ? # %) don't
        # corrupt the DATABASE_URL. Pass via env (not argv) to keep it out of ps.
        dbpw="$(cat "$creds/db-password")"
        dbpw_enc="$(DBPW="$dbpw" ${node}/bin/node -e 'process.stdout.write(encodeURIComponent(process.env.DBPW))')"
        export DATABASE_URL="postgresql://${cfg.database.user}:''${dbpw_enc}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}"
      ''}
      ${lib.optionalString (cfg.admin.passwordFile != null) ''
        export AFFINE_ADMIN_EMAIL="${toString cfg.admin.email}"
        export AFFINE_ADMIN_PASSWORD="$(cat "$creds/admin-password")"
      ''}
      ${lib.optionalString (cfg.storage.provider == "s3") ''
        export AWS_ACCESS_KEY_ID="$(cat "$creds/s3-access-key-id")"
        export AWS_SECRET_ACCESS_KEY="$(cat "$creds/s3-secret-access-key")"
      ''}
      exec ${node}/bin/node ${appDir}/${entry}
    '';

  storageEnv = lib.optionalAttrs (cfg.storage.provider == "s3") {
    # Best-effort S3 (spec §9/§14 #6): confirm the exact var/config mechanism the
    # pinned AFFiNE version uses before relying on this in production.
    AFFINE_STORAGE_PROVIDER = "s3";
    AFFINE_STORAGE_S3_ENDPOINT = cfg.storage.s3.endpoint;
    AFFINE_STORAGE_S3_REGION = cfg.storage.s3.region;
    AFFINE_STORAGE_S3_BUCKET = cfg.storage.s3.bucket;
  };

  # Verified-for-Node systemd hardening (spec §7.1). Differs from the tuwunel
  # (Rust) profile: MemoryDenyWriteExecute must be false (V8 JIT) and the syscall
  # filter must KEEP @ipc (V8 memfd_create). PrivateUsers off for PG peer auth.
  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectProc = "invisible";
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateMounts = true;
    PrivateIPC = true;
    PrivateUsers = false;
    RemoveIPC = true;
    DevicePolicy = "closed";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = false;
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
    CapabilityBoundingSet = [];
    AmbientCapabilities = [];
    SystemCallArchitectures = "native";
    SystemCallErrorNumber = "EPERM";
    SystemCallFilter = [
      "@system-service"
      "~@clock @debug @module @mount @reboot @swap @cpu-emulation @obsolete @timer @chown @setuid @privileged @keyring"
    ];
    UMask = "0077";
  };

  baseService = {
    WorkingDirectory = appDir;
    User = cfg.user;
    Group = cfg.group;
    StateDirectory = "affine";
    StateDirectoryMode = "0700";
  };
in {
  options.services.affine = {
    enable = lib.mkEnableOption "AFFiNE self-hosted server";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.affine-server;
      defaultText = lib.literalExpression "self.packages.\${system}.affine-server";
      description = "The affine-server package (patched OCI image bundle).";
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = defaultUser;
      description = "User the affine server runs as.";
    };
    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = defaultGroup;
      description = "Group the affine server runs as.";
    };

    host = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "127.0.0.1";
      description = "Address the server binds (AFFINE_SERVER_HOST). Keep local behind a proxy.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3010;
      description = "Port the server listens on (AFFINE_SERVER_PORT).";
    };
    externalUrl = lib.mkOption {
      type = lib.types.nonEmptyStr;
      example = "https://affine.example.com";
      description = "Public base URL (AFFINE_SERVER_EXTERNAL_URL). Required; share links/OAuth break without it.";
    };

    database = {
      manage = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable and provision a local PostgreSQL (with pgvector) for AFFiNE.";
      };
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "affine";
        description = "Database name.";
      };
      user = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "affine";
        description = "Database role. When managed locally this equals the system user for peer auth.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "DB host. Empty = local unix socket (peer auth, no password).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "DB port (ignored for the local socket).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to a file with the DB password (sops). Required for remote/BYO DB; unused for local peer auth.";
      };
    };

    redis = {
      manage = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable and provision a local Redis instance for AFFiNE.";
      };
      host = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "127.0.0.1";
        description = "Redis host (REDIS_SERVER_HOST).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 6379;
        description = "Redis port (REDIS_SERVER_PORT).";
      };
    };

    storage = {
      provider = lib.mkOption {
        type = lib.types.enum ["fs" "s3"];
        default = "fs";
        description = "Blob storage backend. 'fs' uses the StateDirectory; 's3' is best-effort (spec §9).";
      };
      s3 = {
        endpoint = lib.mkOption {type = lib.types.str; default = ""; description = "S3 endpoint URL.";};
        region = lib.mkOption {type = lib.types.str; default = ""; description = "S3 region.";};
        bucket = lib.mkOption {type = lib.types.str; default = ""; description = "S3 bucket.";};
        accessKeyIdFile = lib.mkOption {type = lib.types.nullOr lib.types.path; default = null; description = "sops path to the S3 access key id.";};
        secretAccessKeyFile = lib.mkOption {type = lib.types.nullOr lib.types.path; default = null; description = "sops path to the S3 secret access key.";};
      };
    };

    indexer.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the pgvector-backed AI/full-text indexer (AFFINE_INDEXER_ENABLED). Post-v1.";
    };

    nginx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Provision an nginx vhost + ACME TLS in front of the server.";
      };
      hostName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Vhost/ACME hostname (must match externalUrl's host).";
      };
    };

    admin = {
      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional first-admin email to seed (AFFINE_ADMIN_EMAIL). Falls back to /admin if unset.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "sops path to the first-admin password (AFFINE_ADMIN_PASSWORD).";
      };
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {AFFINE_TELEMETRY_ENABLED = "false";};
      description = "Freeform environment passthrough (mailer, feature flags, any AFFINE_* var).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.externalUrl != "";
        message = "services.affine.externalUrl must be set (public base URL).";
      }
      {
        assertion = (cfg.admin.email == null) == (cfg.admin.passwordFile == null);
        message = "services.affine.admin.email and admin.passwordFile must be set together (or both null).";
      }
      {
        assertion = !cfg.database.manage -> (cfg.database.host != "" && cfg.database.passwordFile != null);
        message = "With database.manage = false you must set database.host and database.passwordFile.";
      }
      {
        assertion = cfg.storage.provider == "s3" -> (cfg.storage.s3.endpoint != "" && cfg.storage.s3.bucket != "" && cfg.storage.s3.accessKeyIdFile != null && cfg.storage.s3.secretAccessKeyFile != null);
        message = "storage.provider = \"s3\" requires endpoint, bucket, accessKeyIdFile and secretAccessKeyFile.";
      }
      {
        assertion = cfg.nginx.enable -> cfg.nginx.hostName != "";
        message = "services.affine.nginx.enable requires nginx.hostName.";
      }
    ];

    users.users = lib.mkIf (cfg.user == defaultUser) {
      ${defaultUser} = {
        group = cfg.group;
        home = stateDir;
        isSystemUser = true;
      };
    };
    users.groups = lib.mkIf (cfg.group == defaultGroup) {
      ${defaultGroup} = {};
    };

    services.postgresql = lib.mkIf cfg.database.manage {
      enable = true;
      ensureDatabases = [cfg.database.name];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
      extensions = ps: [ps.pgvector];
    };
    # NB: `extensions` shape drifts across nixpkgs. If eval errors with a type
    # mismatch here, use the list form instead: `extensions = [pkgs.postgresqlPackages.pgvector];`
    # (older trees may only accept `extraPlugins = with pkgs.postgresqlPackages; [pgvector];`).

    services.redis.servers.affine = lib.mkIf cfg.redis.manage {
      enable = true;
      bind = cfg.redis.host;
      port = cfg.redis.port;
    };

    # pgvector is not a "trusted" extension, so the non-superuser affine role
    # can't CREATE EXTENSION itself. Pre-create it as the postgres superuser
    # before migrations run (defensive; migrations may reference vector types
    # even with the indexer off — spec §14 #3).
    systemd.services.affine-db-init = lib.mkIf cfg.database.manage {
      description = "AFFiNE: ensure pgvector extension exists";
      after = ["postgresql.service"];
      requires = ["postgresql.service"];
      before = ["affine-migrate.service"];
      requiredBy = ["affine-migrate.service"];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        ExecStart = ''${config.services.postgresql.package}/bin/psql -d ${cfg.database.name} -c "CREATE EXTENSION IF NOT EXISTS vector"'';
      };
    };

    systemd.services.affine-migrate = {
      description = "AFFiNE database migration / predeploy";
      after = ["network-online.target" "postgresql.service" "redis-affine.service" "affine-db-init.service"];
      wants = ["postgresql.service" "redis-affine.service"];
      requiredBy = ["affine.service"];
      before = ["affine.service"];
      environment = commonEnv;
      serviceConfig =
        baseService
        // hardening
        // {
          Type = "oneshot";
          ExecStart = mkWrapped "scripts/self-host-predeploy.js";
          LoadCredential = credentials;
          RemainAfterExit = false;
        };
    };

    systemd.services.affine = {
      description = "AFFiNE server";
      documentation = ["https://docs.affine.pro/self-host-affine/"];
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "affine-migrate.service" "postgresql.service" "redis-affine.service"];
      wants = ["network-online.target" "postgresql.service" "redis-affine.service"];
      requires = ["affine-migrate.service"];
      environment = commonEnv;
      serviceConfig =
        baseService
        // hardening
        // {
          Type = "exec";
          ExecStart = mkWrapped "dist/main.js";
          LoadCredential = credentials;
          Restart = "on-failure";
          RestartSec = 10;
        };
    };
  };
}
