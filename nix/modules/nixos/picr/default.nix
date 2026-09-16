# NixOS module for PICR (self-hosted photo-sharing server) and its Ping sidecar.
# flake-playground convention: `import ./picr inputs` -> a NixOS module. Runs
# the from-source `picr` package natively under systemd with managed Postgres.
#
# The app resolves media/cache/public/migrations RELATIVE TO cwd and has no env
# override, so we run from a writable state root (stateDir) that symlinks to the
# read-only store. Migrations run in-process at boot; there is no migrate step.
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.picr;
  defaultUser = "picr";

  node = cfg.package.nodejs;
  appDir = "${cfg.package}/dist";

  # Managed => peer auth over the unix socket, no password. The `localhost`
  # authority is a placeholder; `?host=/run/postgresql` selects the socket.
  # VERIFY (spec section 11 #1): node-postgres/drizzle must honor ?host=. If it
  # rejects the socket URL, switch database.manage to TCP + a generated password.
  databaseUrl =
    if cfg.database.manage
    then "postgresql://${cfg.database.user}@localhost/${cfg.database.name}?host=/run/postgresql"
    else "postgresql://${cfg.database.user}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}";

  staticEnv =
    {
      NODE_ENV = "production";
      PORT = toString cfg.port;
      BASE_URL = cfg.baseUrl;
      HOME = cfg.stateDir;
      CONSOLE_LOGGING = lib.boolToString cfg.consoleLogging;
      CAN_WRITE = lib.boolToString cfg.canWrite;
      FILE_WATCHER = cfg.fileWatcher;
      POLLING_SECONDS = toString cfg.pollingSeconds;
      ON_VIEW_SCAN = cfg.onViewScan;
      SCHEDULED_SCAN_HOURS = toString cfg.scheduledScanHours;
      UV_THREADPOOL_SIZE = "8";
      DISABLE_ACCESS_LOGS = lib.boolToString cfg.disableAccessLogs;
    }
    // lib.optionalAttrs (cfg.thumbnailWorkers != null) {
      THUMBNAIL_WORKERS = toString cfg.thumbnailWorkers;
    }
    // lib.optionalAttrs cfg.videoAcceleration.enable ({
        VIDEO_ACCELERATION = "auto";
      }
      // lib.optionalAttrs (cfg.videoAcceleration.device != null) {
        VIDEO_ACCELERATION_DEVICE = cfg.videoAcceleration.device;
      })
    // cfg.extraEnvironment;

  credentials =
    lib.optional (cfg.tokenSecretFile != null) "token-secret:${cfg.tokenSecretFile}"
    ++ lib.optional (cfg.admin.passwordFile != null) "admin-password:${cfg.admin.passwordFile}"
    ++ lib.optional (cfg.pingTokenFile != null) "ping-token:${cfg.pingTokenFile}"
    ++ lib.optional (!cfg.database.manage && cfg.database.passwordFile != null) "db-password:${cfg.database.passwordFile}";

  # ExecStartPre: (re)build the cwd shim in stateDir. ln -sfn so a package
  # upgrade is picked up. cache/ is a real writable dir (thumbnails + logs).
  preStart = pkgs.writeShellScript "picr-prestart" ''
    set -euo pipefail
    ln -sfn ${appDir}/public   ${cfg.stateDir}/public
    ln -sfn ${appDir}/backend  ${cfg.stateDir}/backend
    ln -sfn ${appDir}/version.txt ${cfg.stateDir}/version.txt
    ${lib.optionalString (cfg.mediaDir != "${cfg.stateDir}/media") "ln -sfn ${cfg.mediaDir} ${cfg.stateDir}/media"}
    mkdir -p ${cfg.stateDir}/cache
  '';

  startScript = pkgs.writeShellScript "picr-start" ''
    set -euo pipefail
    creds="''${CREDENTIALS_DIRECTORY:-}"
    ${lib.optionalString (cfg.tokenSecretFile != null) ''export TOKEN_SECRET="$(cat "$creds/token-secret")"''}
    ${lib.optionalString (cfg.admin.passwordFile != null) ''export ADMIN_PASSWORD="$(cat "$creds/admin-password")"''}
    ${lib.optionalString (cfg.pingTokenFile != null) ''export PICR_PING_TOKEN="$(cat "$creds/ping-token")"''}
    ${lib.optionalString (!cfg.database.manage && cfg.database.passwordFile != null) ''
      dbpw="$(cat "$creds/db-password")"
      dbpw_enc="$(DBPW="$dbpw" ${node}/bin/node -e 'process.stdout.write(encodeURIComponent(process.env.DBPW))')"
      export DATABASE_URL="postgresql://${cfg.database.user}:''${dbpw_enc}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}"
    ''}
    exec ${node}/bin/node ${appDir}/server/backend/app.js
  '';

  # Node hardening (reuse the affine module's verified profile).
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
    PrivateDevices = !cfg.videoAcceleration.enable;
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
    SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
  };
in {
  options.services.picr = {
    enable = lib.mkEnableOption "PICR self-hosted photo-sharing server";
    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.picr;
      defaultText = lib.literalExpression "self.packages.\${system}.picr";
      description = "The picr server package (must carry passthru.nodejs).";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = defaultUser;
      description = "User the service runs as.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = defaultUser;
      description = "Group the service runs as.";
    };
    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/picr";
      description = "Writable working directory (StateDirectory).";
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the server binds.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 6900;
      description = "Port the server listens on.";
    };
    baseUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://photos.example.com/";
      description = "Public base URL (BASE_URL). MUST end with '/'.";
    };
    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.stateDir}/media";
      defaultText = lib.literalExpression "\"\${stateDir}/media\"";
      description = "Media library directory (symlinked to cwd/media).";
    };
    canWrite = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow PICR to move/rename/copy media (needs write access).";
    };
    database = {
      manage = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision a local Postgres db+role via peer auth.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "picr";
        description = "Database name.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "picr";
        description = "Database role.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "External DB host (manage = false).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "External DB port (manage = false).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to external DB password (manage = false).";
      };
    };
    tokenSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "TOKEN_SECRET file (>=64 chars). Optional: auto-generated + stored in DB if unset.";
    };
    admin = {
      username = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Initial admin username (first boot only).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Initial admin password file. Optional: random + logged once if unset.";
      };
    };
    pingTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "PICR_PING_TOKEN file (shared with picr-ping; enables the ping endpoint).";
    };
    fileWatcher = lib.mkOption {
      type = lib.types.enum ["native" "polling" "off"];
      default = "native";
      description = "Filesystem watcher mode.";
    };
    pollingSeconds = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = "Polling interval (FILE_WATCHER=polling).";
    };
    onViewScan = lib.mkOption {
      type = lib.types.enum ["off" "direct" "direct_and_new" "one_level"];
      default = "off";
      description = "Demand-driven scan when a folder is viewed.";
    };
    scheduledScanHours = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Whole-library reconcile backstop (hours; 0 = off).";
    };
    thumbnailWorkers = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Thumbnail worker count (null = CPU-aware default).";
    };
    videoAcceleration = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable VAAPI (opens /dev/dri). Groundwork only upstream.";
      };
      device = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/dev/dri/renderD128";
        description = "VAAPI device (multi-GPU only).";
      };
    };
    consoleLogging = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Log to stdout so journalctl shows logs.";
    };
    disableAccessLogs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable AccessLog rows + folder-view notifications.";
    };
    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables (escape hatch).";
    };
    nginx = {
      enable = lib.mkEnableOption "an nginx reverse-proxy vhost for PICR";
      hostName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Virtual host name.";
      };
      forceSSL = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Redirect HTTP to HTTPS.";
      };
      enableACME = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Obtain a Let's Encrypt cert via ACME.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasSuffix "/" cfg.baseUrl;
        message = "services.picr.baseUrl must end with '/'.";
      }
      {
        assertion = !cfg.nginx.enable || cfg.nginx.hostName != null;
        message = "services.picr.nginx.hostName is required when nginx.enable is set.";
      }
    ];

    users.users.${cfg.user} = lib.mkIf (cfg.user == defaultUser) {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
    };
    users.groups.${cfg.group} = lib.mkIf (cfg.group == defaultUser) {};

    services.postgresql = lib.mkIf cfg.database.manage {
      enable = true;
      ensureDatabases = [cfg.database.name];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.stateDir}/cache 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.mediaDir} 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.picr = {
      description = "PICR self-hosted photo-sharing server";
      wantedBy = ["multi-user.target"];
      after = ["network.target"] ++ lib.optional cfg.database.manage "postgresql.service";
      requires = lib.optional cfg.database.manage "postgresql.service";
      environment = staticEnv // {DATABASE_URL = databaseUrl;};
      serviceConfig =
        {
          User = cfg.user;
          Group = cfg.group;
          StateDirectory = "picr";
          WorkingDirectory = cfg.stateDir;
          ExecStartPre = preStart;
          ExecStart = startScript;
          Restart = "on-failure";
          RestartSec = 5;
          LoadCredential = credentials;
          ReadWritePaths =
            [cfg.stateDir]
            ++ lib.optional cfg.canWrite cfg.mediaDir;
          ReadOnlyPaths = lib.optional (!cfg.canWrite) cfg.mediaDir;
          SupplementaryGroups = lib.optional cfg.videoAcceleration.enable "render";
          DeviceAllow = lib.optional cfg.videoAcceleration.enable "/dev/dri rw";
        }
        // hardening;
    };

    services.nginx = lib.mkIf cfg.nginx.enable {
      enable = true;
      virtualHosts.${cfg.nginx.hostName} = {
        forceSSL = cfg.nginx.forceSSL;
        enableACME = cfg.nginx.enableACME;
        locations."/" = {
          proxyPass = "http://${cfg.host}:${toString cfg.port}";
          proxyWebsockets = true;
          extraConfig = "client_max_body_size 0;";
        };
      };
    };
  };
}
