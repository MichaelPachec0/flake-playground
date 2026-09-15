# NixOS module for ProjectSend (Laravel client file-sharing app). Runs the
# prebuilt package natively: php-fpm pool + nginx (X-Accel-Redirect) + two
# queue workers + a per-minute scheduler timer, with optional local MariaDB and
# Redis. flake-playground convention: `import ./projectsend inputs` -> module.
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.projectsend;
  defaultUser = "projectsend";
  defaultGroup = "projectsend";
  stateDir = "/var/lib/projectsend";

  php = cfg.package.php;
  phpSocket = "/run/phpfpm/projectsend.sock";

  # Non-secret baseline .env. Secrets (DB/redis/mail passwords, APP_KEY) are
  # injected as real environment variables per-unit and win over this file;
  # they are deliberately NOT written here.
  envText = let
    kv = lib.mapAttrsToList (n: v: "${n}=${v}");
    base =
      {
        APP_NAME = "ProjectSend";
        APP_ENV = "production";
        APP_DEBUG = "false";
        APP_URL = cfg.appUrl;
        APP_TIMEZONE = "UTC";
        LOG_CHANNEL = "stack";
        LOG_STACK = "single";
        DB_CONNECTION = "mysql";
        DB_HOST = cfg.database.host;
        DB_PORT = toString cfg.database.port;
        DB_DATABASE = cfg.database.name;
        DB_USERNAME = cfg.database.user;
        DB_SOCKET =
          if cfg.database.createLocally
          then cfg.database.socket
          else "";
        SESSION_DRIVER = cfg.session;
        CACHE_STORE = cfg.cache;
        QUEUE_CONNECTION = cfg.queue;
        FILESYSTEM_DISK = "local";
        REDIS_CLIENT = "phpredis";
        REDIS_HOST = cfg.redis.host;
        REDIS_PORT = toString cfg.redis.port;
        MAIL_MAILER = cfg.mail.mailer;
        MAIL_HOST = cfg.mail.host;
        MAIL_PORT = toString cfg.mail.port;
        MAIL_USERNAME = cfg.mail.username;
        MAIL_FROM_ADDRESS = cfg.mail.fromAddress;
        MAIL_FROM_NAME = cfg.mail.fromName;
        MAIL_ENCRYPTION = cfg.mail.encryption;
        PROJECTSEND_FILE_DELIVERY =
          if cfg.nginx.enable
          then "nginx"
          else "php";
      }
      // lib.optionalAttrs (cfg.trustedProxies != "") {TRUSTED_PROXIES = cfg.trustedProxies;}
      // cfg.extraEnv;
  in
    lib.concatStringsSep "\n" (kv base) + "\n";

  envFile = pkgs.writeText "projectsend.env" envText;

  # sops file paths loaded by systemd as credentials, turned into env at
  # runtime so no secret hits the store.
  credentials =
    lib.optional (!cfg.database.createLocally && cfg.database.passwordFile != null) "db-password:${cfg.database.passwordFile}"
    ++ lib.optional (cfg.redis.passwordFile != null) "redis-password:${cfg.redis.passwordFile}"
    ++ lib.optional (cfg.mail.passwordFile != null) "mail-password:${cfg.mail.passwordFile}"
    ++ lib.optional (cfg.appKeyFile != null) "app-key:${cfg.appKeyFile}"
    ++ lib.optional (cfg.admin.passwordFile != null) "admin-password:${cfg.admin.passwordFile}";

  # Shell prelude that exports the secret env vars then runs `cmd`.
  mkWrapped = name: cmd:
    pkgs.writeShellScript "projectsend-${name}" ''
      set -euo pipefail
      export creds="''${CREDENTIALS_DIRECTORY:-}"
      ${lib.optionalString (!cfg.database.createLocally && cfg.database.passwordFile != null) ''
        export DB_PASSWORD="$(cat "$creds/db-password")"
      ''}
      ${lib.optionalString (cfg.redis.passwordFile != null) ''
        export REDIS_PASSWORD="$(cat "$creds/redis-password")"
      ''}
      ${lib.optionalString (cfg.mail.passwordFile != null) ''
        export MAIL_PASSWORD="$(cat "$creds/mail-password")"
      ''}
      ${
        if cfg.appKeyFile != null
        then ''export APP_KEY="$(cat "$creds/app-key")"''
        else ''export APP_KEY="$(cat "${stateDir}/app.key")"''
      }
      cd ${cfg.package}
      exec ${cmd}
    '';

  # ExecStartPre for the fpm pool: render the same secrets into a 0600 file
  # under /run/phpfpm, the RuntimeDirectory the upstream phpfpm module already
  # declares (shared, RuntimeDirectoryPreserve = true) for the phpfpm-<pool>
  # service; EnvironmentFile then loads it. The pool sets clear_env=no so the
  # master's env reaches the workers. The file itself is root:root 0600
  # (umask 077 below), so sharing the 0755 directory with other pools is safe.
  fpmSecretEnv = "/run/phpfpm/projectsend-secret.env";
  fpmRenderSecrets = pkgs.writeShellScript "projectsend-fpm-secrets" ''
    set -euo pipefail
    creds="''${CREDENTIALS_DIRECTORY:-}"
    umask 077
    : > ${fpmSecretEnv}
    ${lib.optionalString (!cfg.database.createLocally && cfg.database.passwordFile != null) ''
      echo "DB_PASSWORD=$(cat "$creds/db-password")" >> ${fpmSecretEnv}
    ''}
    ${lib.optionalString (cfg.redis.passwordFile != null) ''
      echo "REDIS_PASSWORD=$(cat "$creds/redis-password")" >> ${fpmSecretEnv}
    ''}
    ${lib.optionalString (cfg.mail.passwordFile != null) ''
      echo "MAIL_PASSWORD=$(cat "$creds/mail-password")" >> ${fpmSecretEnv}
    ''}
    ${
      if cfg.appKeyFile != null
      then ''echo "APP_KEY=$(cat "$creds/app-key")" >> ${fpmSecretEnv}''
      else ''echo "APP_KEY=$(cat "${stateDir}/app.key")" >> ${fpmSecretEnv}''
    }
  '';
in {
  options.services.projectsend = {
    enable = lib.mkEnableOption "ProjectSend client file-sharing server";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.projectsend;
      defaultText = lib.literalExpression "self.packages.\${system}.projectsend";
      description = "The projectsend package (prebuilt app tree). Its passthru.php is the PHP interpreter used for the pool and CLI.";
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = defaultUser;
      description = "User the app (php-fpm pool, workers, scheduler) runs as.";
    };
    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = defaultGroup;
      description = "Group the app runs as. nginx is added to this group so it can read protected files for X-Accel-Redirect.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = stateDir;
      readOnly = true;
      description = "State directory (writable). Tied to systemd StateDirectory and baked into the package's symlinks, so it cannot be changed here.";
    };

    appUrl = lib.mkOption {
      type = lib.types.nonEmptyStr;
      example = "https://files.example.com";
      description = "Public base URL (APP_URL). Required; links, cookies, and asset URLs break without it.";
    };

    appKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing APP_KEY (base64:...), e.g. a sops secret. When null, a key is generated once and persisted to ${stateDir}/app.key. A changing key invalidates all sessions and encrypted columns.";
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision a local MariaDB (unix-socket auth, no password). Note: upstream officially supports MySQL 8.0+, not MariaDB.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "DB host (ignored when a socket is used).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3306;
        description = "DB port.";
      };
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "projectsend";
        description = "Database name.";
      };
      user = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "projectsend";
        description = "Database user. With createLocally this must equal the system user for MariaDB unix-socket auth.";
      };
      socket = lib.mkOption {
        type = lib.types.str;
        default = "/run/mysqld/mysqld.sock";
        description = "Unix socket path (DB_SOCKET). Used for local socket auth; leave the default when createLocally is on.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to a file with the DB password (sops). Required when createLocally = false; unused for local socket auth.";
      };
    };

    redis = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use Redis for session/cache/queue. When false these default to the database driver.";
      };
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision a local Redis instance (only meaningful when redis.enable).";
      };
      host = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "127.0.0.1";
        description = "Redis host (REDIS_HOST).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 6379;
        description = "Redis port (REDIS_PORT).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to a file with the Redis password (sops). Null = no auth.";
      };
    };

    nginx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision the nginx vhost (X-Accel-Redirect download offload). Set false to front your own proxy and consume the php-fpm socket directly.";
      };
      hostName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Vhost server name. Must match appUrl's host.";
      };
    };

    mail = {
      mailer = lib.mkOption {
        type = lib.types.str;
        default = "smtp";
        description = "MAIL_MAILER.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "MAIL_HOST.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 587;
        description = "MAIL_PORT.";
      };
      username = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "MAIL_USERNAME.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "sops path to MAIL_PASSWORD.";
      };
      fromAddress = lib.mkOption {
        type = lib.types.str;
        default = "projectsend@localhost";
        description = "MAIL_FROM_ADDRESS.";
      };
      fromName = lib.mkOption {
        type = lib.types.str;
        default = "ProjectSend";
        description = "MAIL_FROM_NAME.";
      };
      encryption = lib.mkOption {
        type = lib.types.str;
        default = "tls";
        description = "MAIL_ENCRYPTION (tls/ssl/null).";
      };
    };

    admin = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "Administrator";
        description = "First-admin display name.";
      };
      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "First-admin email. Set with passwordFile to create the admin unattended (projectsend:admin --if-none); leave null to use the web setup screen.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "sops path to the first-admin password.";
      };
    };

    session = lib.mkOption {
      type = lib.types.str;
      default =
        if cfg.redis.enable
        then "redis"
        else "database";
      defaultText = lib.literalExpression ''if cfg.redis.enable then "redis" else "database"'';
      description = "SESSION_DRIVER.";
    };
    cache = lib.mkOption {
      type = lib.types.str;
      default =
        if cfg.redis.enable
        then "redis"
        else "database";
      defaultText = lib.literalExpression ''if cfg.redis.enable then "redis" else "database"'';
      description = "CACHE_STORE.";
    };
    queue = lib.mkOption {
      type = lib.types.str;
      default =
        if cfg.redis.enable
        then "redis"
        else "database";
      defaultText = lib.literalExpression ''if cfg.redis.enable then "redis" else "database"'';
      description = "QUEUE_CONNECTION.";
    };

    trustedProxies = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "TRUSTED_PROXIES (comma-separated IPs/CIDRs, or '*'). Set when a proxy sits in front, else per-IP rate limits and the download IP log collapse.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {PROJECTSEND_EDITION = "community";};
      description = "Extra non-secret environment variables merged into the generated .env.";
    };
  };

  config = lib.mkIf cfg.enable {
    warnings =
      lib.optional cfg.database.createLocally
      "services.projectsend provisions MariaDB locally, but upstream officially supports and tests only MySQL 8.0+. Point database.createLocally = false at an external MySQL for a supported setup.";

    assertions = [
      {
        assertion = cfg.appUrl != "";
        message = "services.projectsend.appUrl must be set (public base URL).";
      }
      {
        assertion = !cfg.database.createLocally -> (cfg.database.host != "" && cfg.database.passwordFile != null);
        message = "services.projectsend: with database.createLocally = false you must set database.host and database.passwordFile.";
      }
      {
        assertion = cfg.database.createLocally -> cfg.database.user == cfg.user;
        message = "services.projectsend: with database.createLocally = true, database.user must equal services.projectsend.user (MariaDB unix-socket auth maps the system user to the DB role).";
      }
      {
        assertion = (cfg.admin.email == null) == (cfg.admin.passwordFile == null);
        message = "services.projectsend.admin.email and admin.passwordFile must be set together (or both null).";
      }
      {
        assertion = cfg.nginx.enable -> cfg.nginx.hostName != "";
        message = "services.projectsend.nginx.enable requires nginx.hostName.";
      }
      {
        assertion = cfg.user != defaultUser -> config ? users.users.${cfg.user};
        message = "services.projectsend: if `user` is changed from the default, that user must already exist.";
      }
      {
        assertion = cfg.group != defaultGroup -> config ? users.groups.${cfg.group};
        message = "services.projectsend: if `group` is changed from the default, that group must already exist.";
      }
    ];

    # Merged with the nginx extraGroups grant below via mkMerge: both assign
    # into users.users, and the module system only merges nested path
    # assignments that don't collide with a sibling full-attrset assignment
    # in the same `config` literal.
    users.users = lib.mkMerge [
      (lib.mkIf (cfg.user == defaultUser) {
        ${defaultUser} = {
          group = cfg.group;
          home = stateDir;
          isSystemUser = true;
        };
      })
      (lib.mkIf cfg.nginx.enable {
        # nginx must read protected files (0640, group projectsend) and
        # traverse the 0750 dirs. Add it to the group.
        ${config.services.nginx.user}.extraGroups = [cfg.group];
      })
    ];
    users.groups = lib.mkIf (cfg.group == defaultGroup) {
      ${defaultGroup} = {};
    };

    # Writable state tree. The package symlinks storage/, bootstrap/cache, .env
    # and public/storage here. Group-executable dirs (0750) so nginx (in the
    # group) can traverse to protected files.
    systemd.tmpfiles.rules = [
      "d ${stateDir}                              0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage                      0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/app                  0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/app/files            0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/app/public           0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/framework            0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/framework/cache      0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/framework/sessions   0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/framework/views      0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/storage/logs                 0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/bootstrap-cache              0750 ${cfg.user} ${cfg.group} - -"
    ];

    # Render the non-secret baseline .env into the state dir on every start.
    systemd.services.projectsend-env = {
      description = "ProjectSend: render baseline .env";
      wantedBy = ["multi-user.target"];
      before = ["phpfpm-projectsend.service" "projectsend-migrate.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.group;
        UMask = "0027";
      };
      script = ''
        install -m 0640 ${envFile} ${stateDir}/.env
      '';
    };

    services.phpfpm.pools.projectsend = {
      user = cfg.user;
      group = cfg.group;
      phpPackage = php;
      settings = {
        "listen" = phpSocket;
        "listen.owner" = cfg.user;
        "listen.group" = cfg.group;
        "listen.mode" = "0660";
        "clear_env" = "no";
        "pm" = "dynamic";
        "pm.max_children" = 10;
        "pm.start_servers" = 2;
        "pm.min_spare_servers" = 2;
        "pm.max_spare_servers" = 4;
        "pm.max_requests" = 500;
        "catch_workers_output" = "yes";
        "php_admin_value[upload_max_filesize]" = "100M";
        "php_admin_value[post_max_size]" = "100M";
        "php_admin_value[memory_limit]" = "256M";
        "php_admin_value[opcache.enable]" = "1";
        "php_admin_value[opcache.validate_timestamps]" = "0";
        "php_admin_value[opcache.max_accelerated_files]" = "20000";
        "php_admin_value[opcache.memory_consumption]" = "192";
        "php_admin_flag[display_errors]" = "off";
        "php_admin_flag[expose_php]" = "off";
      };
    };

    # Inject secrets into the fpm master (workers inherit via clear_env=no) and
    # apply the group-friendly umask so Flysystem's mkdir'd dirs come out 0750.
    systemd.services.phpfpm-projectsend = {
      after = ["projectsend-env.service" "projectsend-migrate.service"];
      wants = ["projectsend-migrate.service"];
      serviceConfig = {
        UMask = "0027";
        LoadCredential = credentials;
        EnvironmentFile = "-${fpmSecretEnv}";
        ExecStartPre = ["${fpmRenderSecrets}"];
      };
    };

    services.nginx = lib.mkIf cfg.nginx.enable {
      enable = true;
      virtualHosts.${cfg.nginx.hostName} = {
        root = "${cfg.package}/public";
        extraConfig = ''
          index index.php;
          client_max_body_size 100m;
          server_tokens off;

          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        '';
        locations."/" = {
          tryFiles = "$uri $uri/ /index.php?$query_string";
        };
        locations."^~ /protected-files/" = {
          extraConfig = ''
            internal;
            alias ${stateDir}/storage/app/files/;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;
            add_header Content-Security-Policy "sandbox; default-src 'none'" always;
          '';
        };
        locations."~ \\.php$" = {
          extraConfig = ''
            try_files $uri =404;
            fastcgi_pass unix:${phpSocket};
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            include ${config.services.nginx.package}/conf/fastcgi_params;
            fastcgi_buffer_size 32k;
            fastcgi_buffers 8 32k;
          '';
        };
        locations."~ /\\.(?!well-known)" = {
          extraConfig = "deny all;";
        };
      };
    };

    services.mysql = lib.mkIf cfg.database.createLocally {
      enable = true;
      package = pkgs.mariadb;
      ensureDatabases = [cfg.database.name];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensurePermissions = {"${cfg.database.name}.*" = "ALL PRIVILEGES";};
        }
      ];
    };

    services.redis.servers.projectsend = lib.mkIf (cfg.redis.enable && cfg.redis.createLocally) {
      enable = true;
      bind = cfg.redis.host;
      port = cfg.redis.port;
    };

    # Generate and persist APP_KEY once, when no appKeyFile is provided. --show
    # prints the key (does not write .env), keeping it out of the baseline file;
    # all units read it back from app.key.
    systemd.services.projectsend-appkey = lib.mkIf (cfg.appKeyFile == null) {
      description = "ProjectSend: generate and persist APP_KEY";
      wantedBy = ["multi-user.target"];
      before = ["projectsend-migrate.service" "phpfpm-projectsend.service"];
      after = ["projectsend-env.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.group;
        UMask = "0077";
      };
      script = ''
        if [ ! -s ${stateDir}/app.key ]; then
          ${php}/bin/php ${cfg.package}/artisan key:generate --show > ${stateDir}/app.key
        fi
      '';
    };

    systemd.services.projectsend-migrate = {
      description = "ProjectSend: migrate and provision on boot";
      wantedBy = ["multi-user.target"];
      requiredBy = ["phpfpm-projectsend.service"];
      before = ["phpfpm-projectsend.service"];
      after =
        ["network-online.target" "projectsend-env.service"]
        ++ lib.optional (cfg.appKeyFile == null) "projectsend-appkey.service"
        ++ lib.optional cfg.database.createLocally "mysql.service"
        ++ lib.optional (cfg.redis.enable && cfg.redis.createLocally) "redis-projectsend.service";
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.group;
        UMask = "0027";
        LoadCredential = credentials;
        ExecStart = mkWrapped "migrate" ''
          ${pkgs.bash}/bin/bash -c '
            i=0
            until ${php}/bin/php ${cfg.package}/artisan db:show --quiet 2>/dev/null; do
              i=$((i+1))
              if [ "$i" -ge 60 ]; then
                echo "projectsend: gave up waiting for the database after 60s" >&2
                exit 1
              fi
              sleep 1
            done
            ${php}/bin/php ${cfg.package}/artisan projectsend:update
            ${php}/bin/php ${cfg.package}/artisan projectsend:seed-settings
            ${lib.optionalString (cfg.admin.email != null) ''
            ADMIN_PASSWORD="$(cat "$creds/admin-password")" \
            ${php}/bin/php ${cfg.package}/artisan projectsend:admin --if-none \
              --name=${lib.escapeShellArg cfg.admin.name} \
              --email=${lib.escapeShellArg cfg.admin.email} \
              --password="$ADMIN_PASSWORD"
          ''}
          '
        '';
      };
    };

    systemd.services.projectsend-worker = {
      description = "ProjectSend: default queue worker";
      wantedBy = ["multi-user.target"];
      after = ["projectsend-migrate.service"];
      requires = ["projectsend-migrate.service"];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0027";
        LoadCredential = credentials;
        ExecStart = mkWrapped "worker" "${php}/bin/php ${cfg.package}/artisan queue:work default --tries=3 --max-time=3600";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Zip builds get a dedicated worker: BuildZipDownloadJob allows itself an
    # hour, and on a shared queue one large archive holds up notification email.
    systemd.services.projectsend-worker-zips = {
      description = "ProjectSend: zip queue worker";
      wantedBy = ["multi-user.target"];
      after = ["projectsend-migrate.service"];
      requires = ["projectsend-migrate.service"];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0027";
        LoadCredential = credentials;
        ExecStart = mkWrapped "worker-zips" "${php}/bin/php ${cfg.package}/artisan queue:work zips --tries=1 --max-time=3600";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Laravel scheduler as a per-minute timer (cron equivalent), not a
    # long-running schedule:work daemon.
    systemd.timers.projectsend-scheduler = {
      description = "ProjectSend: run the scheduler every minute";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "minutely";
        Persistent = false;
      };
    };
    systemd.services.projectsend-scheduler = {
      description = "ProjectSend: scheduler tick";
      after = ["projectsend-migrate.service"];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0027";
        LoadCredential = credentials;
        ExecStart = mkWrapped "scheduler" "${php}/bin/php ${cfg.package}/artisan schedule:run";
      };
    };
  };
}
