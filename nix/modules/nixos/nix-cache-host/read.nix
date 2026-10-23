# Read path: Harmonia on loopback, nginx in front with per-token auth, a path
# allowlist (only what substitution needs), per-user connection limits and a
# JSON access log for the pruner. Auth protects confidentiality and
# bandwidth; integrity comes only from the repo signatures Harmonia serves
# from the Nix DB (it has no signing key of its own).
{
  config,
  lib,
  ...
}: let
  cfg = config.services.nix-cache-host;
  upstream = "http://127.0.0.1:${toString cfg.harmonia.port}";
  proxied = extra: {
    proxyPass = upstream;
    extraConfig = extra;
  };
  rotate = config.services.logrotate.settings;
  isSet = s: k: (s.${k} or null) == true;
in {
  config = lib.mkIf cfg.enable {
    # The pruner follows the access log across a rotation only by rename +
    # reopen, reading the previous file as <log>.1, uncompressed. The NixOS
    # nginx module's logrotate section (/var/log/nginx/*.log: rename, USR1
    # reopen, delaycompress, no dateext) does exactly that; a host override
    # that breaks it would silently lose hits, so refuse it.
    assertions = [
      {
        assertion =
          !config.services.logrotate.enable
          || !(rotate.nginx.enable or false)
          || (!(isSet rotate.nginx "copytruncate")
            && !(isSet rotate.nginx "dateext")
            && !(isSet (rotate.header or {}) "dateext")
            && (!(isSet rotate.nginx "compress") || isSet rotate.nginx "delaycompress"));
        message = "services.nix-cache-host: services.logrotate.settings.nginx must rotate by rename (no copytruncate), without dateext and with delaycompress if compress is on, so the pruner can read /var/log/nginx/nix-cache.access.log.1";
      }
    ];

    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [];
      settings = {
        bind = "127.0.0.1:${toString cfg.harmonia.port}";
        priority = cfg.priority;
      };
    };

    services.nginx = {
      enable = true;
      # Fields read by the pruner's access-log parser: t (ISO 8601 with
      # offset), u (basic-auth user), uri (with ?hash= on NAR URLs), s.
      # commonHttpConfig, not appendHttpConfig: nginx needs log_format defined
      # before the server blocks that use it, and appendHttpConfig is rendered
      # after them.
      commonHttpConfig = ''
        log_format nix_cache_json escape=json '{"t":"$time_iso8601","u":"$remote_user","uri":"$request_uri","s":$status,"b":$body_bytes_sent}';
        limit_conn_zone $remote_user zone=nix_cache_user:10m;
        # Requests WITHOUT credentials are rate limited per IP. Requests with
        # credentials cannot be told apart before the auth check, and a wrong
        # token costs no more to reject than a missing one ({SSHA}).
        map $http_authorization $nix_cache_anon {
          "" $binary_remote_addr;
          default "";
        }
        limit_req_zone $nix_cache_anon zone=nix_cache_anon:10m rate=30r/m;
      '';

      virtualHosts.${cfg.hostName} =
        {
          forceSSL = true;
          useACMEHost = cfg.nginx.useACMEHost;
          basicAuthFile = cfg.htpasswdFile;
          extraConfig = ''
            access_log /var/log/nginx/nix-cache.access.log nix_cache_json;
            error_log /var/log/nginx/nix-cache.error.log;
            limit_conn nix_cache_user ${toString cfg.nginx.maxConnsPerUser};
            limit_req zone=nix_cache_anon burst=20 nodelay;
            limit_req_status 429;
          '';
          locations = {
            "= /nix-cache-info" = proxied "";
            "~ \"^/[0-9a-df-np-sv-z]{32}\\.narinfo$\"" = proxied "";
            "^~ /nar/" = proxied ''
              limit_rate ${cfg.nginx.limitRate};
              proxy_buffering off;
            '';
            # Everything else Harmonia offers (/serve/, /log/, .ls, ...) is not
            # needed for substitution.
            "/".return = "404";
          };
        }
        // lib.optionalAttrs (cfg.nginx.sslCertificate != null) {
          inherit (cfg.nginx) sslCertificate sslCertificateKey;
        };

      virtualHosts.nix-cache-default-server = lib.mkIf cfg.nginx.defaultServer {
        serverName = "_";
        default = true;
        rejectSSL = true;
        locations."/".return = "444";
      };
    };

    networking.firewall.allowedTCPPorts = [80 443];

    # Unknown token users are guessing: ban. A KNOWN user with a wrong token is
    # a host on a retired token generation; the pruner alerts on that instead
    # (banning it would only make its substitutions time out).
    services.fail2ban.jails.nix-cache-guess = lib.mkIf cfg.fail2ban.enable {
      filter.Definition = {
        failregex = ''^.* user "[^"]*" was not found in "[^"]*", client: <HOST>, server: '';
        ignoreregex = "";
      };
      settings = {
        logpath = "/var/log/nginx/nix-cache.error.log";
        backend = "auto";
        port = "http,https";
        findtime = "10m";
        maxretry = 5;
        bantime = "24h";
        # Repeat offenders get longer bans each time.
        "bantime.increment" = true;
      };
    };
    # A jail whose logpath does not exist yet fails fail2ban at boot.
    systemd.services.fail2ban = lib.mkIf cfg.fail2ban.enable {
      after = ["nginx.service"];
      wants = ["nginx.service"];
    };
  };
}
