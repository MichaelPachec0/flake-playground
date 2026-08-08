# NixOS module: run DAWNCR0W/affine-mcp-server (write-capable AFFiNE MCP server)
# as a hardened systemd service. Standalone: targets any AFFiNE via `baseUrl`
# (local or remote), authenticating with email+password, a session cookie, or an
# API token. Secrets flow through systemd LoadCredential + a runtime wrapper, so
# nothing lands in the Nix store. See
# docs/superpowers/specs/2026-07-24-mcp-affine-nixos-module-design.md
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mcp.affine;
  stateDir = "/var/lib/mcp-affine";

  isLoopback = h: builtins.elem h ["127.0.0.1" "::1" "localhost"];

  # The affine module may or may not be imported alongside this one (the eval
  # check imports mcp ALONE), so guard the cross-module read.
  affineEnabled = config.services.affine.enable or false;

  hasEmailAuth = cfg.emailFile != null && cfg.passwordFile != null;
  hasAnyAuth = hasEmailAuth || cfg.cookieFile != null || cfg.apiTokenFile != null;

  # Non-secret environment; only emit vars that are set/relevant.
  serviceEnv =
    {
      MCP_TRANSPORT = cfg.transport;
      AFFINE_BASE_URL = cfg.baseUrl;
      AFFINE_GRAPHQL_PATH = cfg.graphqlPath;
      AFFINE_MCP_HTTP_HOST = cfg.http.host;
      PORT = toString cfg.http.port;
      AFFINE_MCP_AUTH_MODE = cfg.http.authMode;
      AFFINE_TOOL_PROFILE = cfg.toolProfile;
      XDG_CONFIG_HOME = stateDir;
    }
    // lib.optionalAttrs (cfg.workspaceId != null) {AFFINE_WORKSPACE_ID = cfg.workspaceId;}
    // lib.optionalAttrs cfg.allowInsecureHttp {AFFINE_ALLOW_INSECURE_HTTP = "true";}
    // lib.optionalAttrs cfg.http.allowUnauthenticated {AFFINE_MCP_HTTP_ALLOW_UNAUTHENTICATED = "true";}
    // lib.optionalAttrs (cfg.disabledGroups != []) {AFFINE_DISABLED_GROUPS = lib.concatStringsSep "," cfg.disabledGroups;}
    // lib.optionalAttrs (cfg.disabledTools != []) {AFFINE_DISABLED_TOOLS = lib.concatStringsSep "," cfg.disabledTools;}
    // cfg.extraEnvironment;

  # LoadCredential entries "id:path" for each provided secret file.
  credList =
    lib.optional (cfg.emailFile != null) "affine-email:${cfg.emailFile}"
    ++ lib.optional (cfg.passwordFile != null) "affine-password:${cfg.passwordFile}"
    ++ lib.optional (cfg.cookieFile != null) "affine-cookie:${cfg.cookieFile}"
    ++ lib.optional (cfg.apiTokenFile != null) "affine-api-token:${cfg.apiTokenFile}"
    ++ lib.optional (cfg.http.tokenFile != null) "http-token:${cfg.http.tokenFile}";

  # Compose secret env from credential files at runtime, then exec the package's launcher.
  wrapper = pkgs.writeShellScript "mcp-affine-start" ''
    set -euo pipefail
    creds="''${CREDENTIALS_DIRECTORY:-}"
    ${lib.optionalString (cfg.emailFile != null) ''export AFFINE_EMAIL="$(cat "$creds/affine-email")"''}
    ${lib.optionalString (cfg.passwordFile != null) ''export AFFINE_PASSWORD="$(cat "$creds/affine-password")"''}
    ${lib.optionalString (cfg.cookieFile != null) ''export AFFINE_COOKIE="$(cat "$creds/affine-cookie")"''}
    ${lib.optionalString (cfg.apiTokenFile != null) ''export AFFINE_API_TOKEN="$(cat "$creds/affine-api-token")"''}
    ${lib.optionalString (cfg.http.tokenFile != null) ''export AFFINE_MCP_HTTP_TOKEN="$(cat "$creds/http-token")"''}
    exec ${lib.getExe cfg.package}
  '';

  # Node-safe hardening (V8 JIT needs MemoryDenyWriteExecute=false + @ipc kept).
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
    PrivateUsers = true;
    RemoveIPC = true;
    DevicePolicy = "closed";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = false;
    # AF_NETLINK is needed for outbound DNS: unlike the affine module this profile
    # was copied from (which only talks to a local Postgres over AF_UNIX), this
    # service resolves a possibly-remote AFFiNE host, and glibc getaddrinfo opens
    # an AF_NETLINK socket for RFC-3484 source-address sorting.
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK"];
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
in {
  options.mcp.affine = {
    enable = lib.mkEnableOption "DAWNCR0W AFFiNE MCP server";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.affine-mcp-server;
      defaultText = lib.literalExpression "self.packages.\${system}.affine-mcp-server";
      description = "The affine-mcp-server package to run.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.nonEmptyStr;
      example = "https://affine.example.com";
      description = "AFFiNE instance URL the server connects to (AFFINE_BASE_URL). Local or remote.";
    };
    graphqlPath = lib.mkOption {
      type = lib.types.str;
      default = "/graphql";
      description = "AFFiNE GraphQL route (AFFINE_GRAPHQL_PATH).";
    };
    workspaceId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Default workspace id (AFFINE_WORKSPACE_ID). Null = server default.";
    };
    allowInsecureHttp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow a non-TLS (http://) AFFiNE baseUrl (AFFINE_ALLOW_INSECURE_HTTP). Needed for a plain-http local AFFiNE.";
    };

    emailFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file with the AFFiNE account email (AFFINE_EMAIL). Set together with passwordFile.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file with the AFFiNE account password (AFFINE_PASSWORD). Set together with emailFile.";
    };
    cookieFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file with an AFFiNE session cookie (AFFINE_COOKIE). Alternative to email/password.";
    };
    apiTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file with an AFFiNE API token (AFFINE_API_TOKEN). Alternative to email/password.";
    };

    transport = lib.mkOption {
      type = lib.types.enum ["http" "stdio"];
      default = "http";
      description = "MCP transport (MCP_TRANSPORT). Only 'http' is meaningful for a long-running service.";
    };

    http = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Bind address of the MCP HTTP endpoint (AFFINE_MCP_HTTP_HOST). Keep loopback unless exposing to a network.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 7021;
        description = "Port of the MCP HTTP endpoint (PORT).";
      };
      authMode = lib.mkOption {
        type = lib.types.enum ["bearer" "oauth"];
        default = "bearer";
        description = "Inbound endpoint auth strategy (AFFINE_MCP_AUTH_MODE). 'oauth' needs extra issuer vars via extraEnvironment (out of scope for v1).";
      };
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to a bearer token file protecting the MCP HTTP endpoint (AFFINE_MCP_HTTP_TOKEN).";
      };
      allowUnauthenticated = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow the bearer listener to start with no token (AFFINE_MCP_HTTP_ALLOW_UNAUTHENTICATED). Intended for a loopback/trusted-network listener.";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open http.port in the firewall (for remote MCP clients).";
    };

    toolProfile = lib.mkOption {
      type = lib.types.enum ["full" "read_only" "core" "authoring"];
      default = "full";
      description = "Exposed tool surface (AFFINE_TOOL_PROFILE). Use read_only/core/authoring to reduce write/destructive tools.";
    };
    disabledGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["destructive" "admin"];
      description = "Tool groups to disable (AFFINE_DISABLED_GROUPS), joined with commas.";
    };
    disabledTools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Specific tools to disable (AFFINE_DISABLED_TOOLS), joined with commas.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {AFFINE_LOGIN_AT_START = "sync";};
      description = "Freeform environment passthrough for any other AFFINE_*/MCP_* var (WebSocket tuning, OAuth, CORS, ...).";
    };

    memoryMax = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "1024M";
      example = "2G";
      description = "systemd MemoryMax cap for the service. Bump for blob-heavy tool use (large uploads); on OOM the cgroup kill + Restart=on-failure recovers.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.baseUrl != "";
        message = "mcp.affine.baseUrl must be set (the AFFiNE instance URL).";
      }
      {
        assertion = hasAnyAuth;
        message = "mcp.affine: provide an AFFiNE credential: emailFile + passwordFile, or cookieFile, or apiTokenFile.";
      }
      {
        assertion = (cfg.emailFile == null) == (cfg.passwordFile == null);
        message = "mcp.affine.emailFile and passwordFile must be set together (email auth needs both).";
      }
      {
        assertion =
          cfg.transport != "http" || cfg.http.authMode != "bearer"
          || cfg.http.tokenFile != null || cfg.http.allowUnauthenticated;
        message = "mcp.affine: an http bearer listener needs http.tokenFile, or set http.allowUnauthenticated = true for a loopback/trusted listener.";
      }
      {
        assertion = cfg.http.authMode != "oauth";
        message = "mcp.affine: http.authMode = \"oauth\" is not wired in v1. Supply AFFINE_MCP_PUBLIC_BASE_URL + AFFINE_OAUTH_ISSUER_URL via extraEnvironment and use authMode via extraEnvironment instead.";
      }
    ];

    warnings =
      lib.optional (cfg.http.allowUnauthenticated && !isLoopback cfg.http.host)
      "mcp.affine: http.allowUnauthenticated = true with a non-loopback http.host (${cfg.http.host}) exposes an UNAUTHENTICATED write-capable MCP endpoint to the network."
      ++ lib.optional (cfg.transport == "stdio")
      "mcp.affine: transport = \"stdio\" has no long-running listener; the systemd service assumes http. Use a client-spawned stdio config instead.";

    systemd.services.mcp-affine = {
      description = "AFFiNE MCP server (DAWNCR0W), write-capable";
      documentation = ["https://github.com/DAWNCR0W/affine-mcp-server"];
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"] ++ lib.optional affineEnabled "affine.service";
      wants = ["network-online.target"] ++ lib.optional affineEnabled "affine.service";
      environment = serviceEnv;
      serviceConfig =
        {
          DynamicUser = true;
          StateDirectory = "mcp-affine";
          StateDirectoryMode = "0700";
          ExecStart = wrapper;
          LoadCredential = credList;
          Type = "exec";
          Restart = "on-failure";
          RestartSec = 5;
          MemoryMax = cfg.memoryMax;
        }
        // hardening;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.http.port];
  };
}
