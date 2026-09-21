# NixOS module for pingvin-share-x (nix/pkgs/playground/pingvin-share.nix).
# Runs NestJS backend + Next.js frontend as native systemd services.
# Optional nginx vhost splits /api (upstream uses a bundled Caddy instead).
# Config: declarative `settings` -> config.yaml; secrets spliced in at
# runtime from LoadCredential, never land in the store. SQLite only.
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.pingvin-share-x;
  defaultUser = "pingvin-share";
  defaultGroup = "pingvin-share";

  pkg = cfg.package;
  node = pkg.passthru.nodejs;
  engines = pkg.passthru.prismaEngines;

  dataDir = cfg.dataDir;
  configYaml = "${cfg.stateDir}/config.yaml";

  # Non-secret settings rendered to store JSON; runtime composer turns this
  # into YAML and merges in secrets.
  baseSettingsJson = pkgs.writeText "pingvin-base-settings.json" (builtins.toJSON cfg.settings);
  # yaml module: from the backend's node_modules, a runtime dep.
  yamlModule = "${pkg}/backend/node_modules/yaml";
  composeScript = ./compose-config.js;

  secretKeys = lib.attrNames cfg.secrets;
  credentials = lib.mapAttrsToList (k: v: "${k}:${v}") cfg.secrets;

  # Empty settings (default) = pure UI mode: no config.yaml, admin
  # configures via web UI. Compose config.yaml + set CONFIG_FILE only when
  # settings/secrets are declared.
  #
  # When false: CONFIG_FILE unset, backend falls back to its own default
  # "../config.yaml" (relative to read-only store WorkingDirectory), which
  # never exists. loadYamlConfig's read fails, YAML parses "" to null, and
  # yamlConfig-gated code (migrateInitUser etc.) is skipped - no default
  # needed for it.
  #
  # migrate deploy + DB seed always run regardless; only compose +
  # CONFIG_FILE depend on this flag.
  hasConfig = cfg.settings != {} || cfg.secrets != {};

  commonEnv =
    {
      NODE_ENV = "production";
      DATA_DIRECTORY = dataDir;
      DATABASE_URL = "file:${dataDir}/pingvin-share.db?connection_limit=1";
      BACKEND_PORT = toString cfg.backendPort;
      PRISMA_QUERY_ENGINE_LIBRARY = "${engines}/lib/libquery_engine.so.node";
      PRISMA_SCHEMA_ENGINE_BINARY = "${engines}/bin/schema-engine";
      # Mirrors build-time prismaEnv (pingvin-share.nix): without this,
      # `prisma migrate deploy` may try a telemetry checkpoint call at boot.
      CHECKPOINT_DISABLE = "1";
    }
    // lib.optionalAttrs hasConfig {CONFIG_FILE = configYaml;}
    // lib.optionalAttrs (cfg.clamav.host != null) {CLAMAV_HOST = cfg.clamav.host;}
    // lib.optionalAttrs (cfg.clamav.port != null) {CLAMAV_PORT = toString cfg.clamav.port;}
    // lib.optionalAttrs cfg.nginx.enable {TRUST_PROXY = "true";}
    // cfg.extraEnvironment;

  # Compose config.yaml; runs only when hasConfig (see migrate unit's
  # ExecStartPre below). migrate + seed always run regardless.
  composeConfig = ''
    PINGVIN_SECRET_KEYS="${lib.concatStringsSep "," secretKeys}" \
      ${node}/bin/node ${composeScript} ${baseSettingsJson} ${configYaml} ${yamlModule}
  '';

  # Node-safe hardening: V8 JIT needs W^X off, @ipc kept. Mirrors the
  # affine module's verified profile.
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
    User = cfg.user;
    Group = cfg.group;
    StateDirectory = "pingvin-share";
    StateDirectoryMode = "0750";
    # StateDirectory only auto-covers /var/lib/pingvin-share (+ dataDir's
    # default /data subdir). Custom stateDir/dataDir need listing here or
    # ProtectSystem=strict makes them read-only. tmpfiles rules below
    # create them with the right owner before any unit starts.
    ReadWritePaths = lib.unique [cfg.stateDir cfg.dataDir];
  };
in {
  options.services.pingvin-share-x = {
    enable = lib.mkEnableOption "pingvin-share-x file sharing server";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pingvin-share-x;
      defaultText = lib.literalExpression "self.packages.\${system}.pingvin-share-x";
      description = "The pingvin-share package (stable by default; set to pingvin-share-x-beta for the v2 beta).";
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = defaultUser;
      description = "User the services run as.";
    };
    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = defaultGroup;
      description = "Group the services run as.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pingvin-share";
      description = "State directory (holds config.yaml + the writable frontend public tree).";
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pingvin-share/data";
      description = "Data directory: SQLite DB + uploads.";
    };

    host = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "127.0.0.1";
      description = ''
        Bind address for the frontend only (passed as HOSTNAME to the
        Next.js server). Upstream's NestJS backend (backend/src/main.ts)
        calls app.listen(port) with no host argument, so it always binds
        all interfaces regardless of this setting -- there is no
        backend-side bind/host env to wire it to. This module does not
        open the firewall for backendPort; keep it firewalled (or behind
        the optional nginx vhost) if the host is not otherwise trusted.
      '';
    };
    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Backend (NestJS) port (BACKEND_PORT).";
    };
    frontendPort = lib.mkOption {
      type = lib.types.port;
      default = 3333;
      description = "Frontend (Next.js) port.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      example = lib.literalExpression ''
        {
          general.appUrl = "https://share.example.com";
          initUser = { enabled = true; email = "admin@example.com"; username = "admin"; isAdmin = true; };
        }
      '';
      description = "Freeform config rendered to config.yaml. Keys present here override the DB and lock the UI. initUser seeds the first admin.";
    };
    secrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      example = lib.literalExpression ''{ "smtp.password" = "/run/secrets/pingvin-smtp"; }'';
      description = "Map of dotted config key (category.name) -> file whose contents are spliced into config.yaml at runtime (via LoadCredential). Keeps secrets out of the store.";
    };

    clamav = {
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ClamAV host (CLAMAV_HOST). null disables the env override.";
      };
      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "ClamAV port (CLAMAV_PORT).";
      };
    };

    nginx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Provision an nginx vhost that splits /api -> backend, rest -> frontend, with ACME TLS.";
      };
      hostName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Vhost / ACME hostname. Required when nginx.enable.";
      };
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Freeform environment passthrough for the backend.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.nginx.enable -> cfg.nginx.hostName != "";
        message = "services.pingvin-share-x.nginx.enable requires nginx.hostName.";
      }
      {
        assertion = cfg.user != defaultUser -> config ? users.users.${cfg.user};
        message = "services.pingvin-share-x: a non-default user must already exist.";
      }
      {
        assertion = cfg.group != defaultGroup -> config ? users.groups.${cfg.group};
        message = "services.pingvin-share-x: a non-default group must already exist.";
      }
    ];

    users.users = lib.mkIf (cfg.user == defaultUser) {
      ${defaultUser} = {
        group = cfg.group;
        home = cfg.stateDir;
        isSystemUser = true;
      };
    };
    users.groups = lib.mkIf (cfg.group == defaultGroup) {${defaultGroup} = {};};

    # Seed writable public/ via tmpfiles (runs at boot, outside any unit's
    # mount namespace). Not an in-unit ExecStartPre: the frontend unit's own
    # BindPaths already shadows ${pkg}/frontend/public with
    # ${cfg.stateDir}/public by then, so an in-unit `cp` would copy the
    # empty target over itself.
    #
    # `C` copies only if destination is missing/empty: a one-time seed, not
    # a resync every boot.
    #
    # `d` entries create stateDir/dataDir with the right owner before any
    # unit starts (StateDirectory only auto-creates the default path); they
    # run before the `C` rule so its parent dir already exists.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "C ${cfg.stateDir}/public 0750 ${cfg.user} ${cfg.group} - ${pkg}/frontend/public"
    ];

    systemd.services.pingvin-share-migrate = {
      description = "pingvin-share: compose config + DB migrate/seed";
      after = ["network.target"];
      requiredBy = ["pingvin-share-backend.service"];
      before = ["pingvin-share-backend.service"];
      environment = commonEnv;
      path = [node];
      serviceConfig =
        baseService
        // hardening
        // {
          Type = "oneshot";
          # "active (exited)" after success, not "inactive"; matches the
          # projectsend module's oneshot pattern.
          RemainAfterExit = true;
          LoadCredential = credentials;
          ExecStartPre = pkgs.writeShellScript "pingvin-compose-config" (
            ''
              set -euo pipefail
              mkdir -p ${dataDir}
            ''
            + lib.optionalString hasConfig composeConfig
          );
          # Always run (regardless of hasConfig), from the backend tree
          # with the pinned node.
          ExecStart = pkgs.writeShellScript "pingvin-migrate" ''
            set -euo pipefail
            cd ${pkg}/backend
            ${node}/bin/node node_modules/prisma/build/index.js migrate deploy
            ${node}/bin/node dist/prisma/seed/config.seed.js
          '';
          WorkingDirectory = "${pkg}/backend";
        };
    };

    systemd.services.pingvin-share-backend = {
      description = "pingvin-share backend (NestJS)";
      wantedBy = ["multi-user.target"];
      after = ["network.target" "pingvin-share-migrate.service"];
      requires = ["pingvin-share-migrate.service"];
      environment = commonEnv;
      path = [node];
      serviceConfig =
        baseService
        // hardening
        // {
          Type = "exec";
          WorkingDirectory = "${pkg}/backend";
          ExecStart = "${node}/bin/node ${pkg}/backend/dist/src/main";
          LoadCredential = credentials;
          Restart = "on-failure";
          RestartSec = 10;
        };
    };

    systemd.services.pingvin-share-frontend = {
      description = "pingvin-share frontend (Next.js)";
      wantedBy = ["multi-user.target"];
      # systemd-tmpfiles-setup seeds ${cfg.stateDir}/public (see tmpfiles
      # rule above) before BindPaths mounts it over the read-only store copy.
      after = ["network.target" "pingvin-share-backend.service" "systemd-tmpfiles-setup.service"];
      environment = {
        NODE_ENV = "production";
        PORT = toString cfg.frontendPort;
        HOSTNAME = cfg.host;
        API_URL = "http://127.0.0.1:${toString cfg.backendPort}";
      };
      serviceConfig =
        baseService
        // hardening
        // {
          Type = "exec";
          # Frontend writes uploaded branding into public/img: bind a
          # writable state copy (seeded above) over the read-only store tree.
          RuntimeDirectory = "pingvin-share-frontend";
          BindPaths = ["${cfg.stateDir}/public:${pkg}/frontend/public"];
          WorkingDirectory = "${pkg}/frontend";
          ExecStart = "${node}/bin/node ${pkg}/frontend/server.js";
          Restart = "on-failure";
          RestartSec = 10;
        };
    };

    services.nginx = lib.mkIf cfg.nginx.enable {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${cfg.nginx.hostName} = {
        enableACME = true;
        forceSSL = true;
        locations."/api/".proxyPass = "http://127.0.0.1:${toString cfg.backendPort}";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.frontendPort}";
          proxyWebsockets = true;
        };
      };
    };
  };
}
