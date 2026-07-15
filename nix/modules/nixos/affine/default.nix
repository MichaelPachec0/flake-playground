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
  };
}
