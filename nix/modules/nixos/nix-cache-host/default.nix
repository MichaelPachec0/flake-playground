# Self-hosted Nix binary cache host (services.nix-cache-host).
#
# Read path: Harmonia on loopback behind nginx, which requires a per-host
# token on every request ({SSHA} htpasswd), allows only the substitution
# endpoints and logs JSON lines for the pruner. Write path: one SSH account
# per CI repo whose only possible action is a forced, size-capped upload; a
# sandboxed importer checks the repo's own signatures before the daemon
# imports anything. Retention: an hourly pruner keeps a tiered-LRU set under
# a byte budget and a root GC unit collects the rest. One file per concern.
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nix-cache-host;
  inherit (lib) mkOption types;
  gib = n: n * 1024 * 1024 * 1024;

  # Secrets are named by a string, never a Nix path: a path literal would be
  # copied into the world-readable store the moment it is interpolated.
  secretPath =
    types.addCheck types.str (s: lib.hasPrefix "/" s && !lib.hasPrefix "${builtins.storeDir}/" s)
    // {description = "absolute path outside the Nix store, as a string";};

  # The alert command lands in a systemd ExecStart and a bash script, so it
  # is one absolute executable path from a conservative charset: no
  # whitespace, quotes, `%` (systemd specifiers) or shell metacharacters.
  # Wrap anything needing arguments in a script (pkgs.writeShellScript).
  alertCommandType =
    types.strMatching "/[A-Za-z0-9._+@=:,/-]+"
    // {description = "absolute path of one executable (no whitespace, quotes, % or shell metacharacters)";};

  # One authorized_keys line: a key type, base64, an optional printable-ASCII
  # comment. No newline can slip through to add a second, unrestricted line,
  # and no leading options can be smuggled in ahead of the module's own.
  sshKeyType = types.strMatching "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/]+={0,3}( [ -~]*)?";

  repoModule = {name, ...}: {
    options = {
      uid = mkOption {
        type = types.int;
        description = ''
          Fixed UID and GID of cache-drop-${name}. Fixed so the systemd slice
          limits (user-<uid>.slice) and the egress rule can name it.
        '';
      };
      signingPublicKeys = mkOption {
        type = types.listOf types.str;
        description = ''
          Nix signing public keys (name:base64) this repo's CI signs with.
          Every path in a bundle from this repo must carry a valid signature
          from one of them; they are also added to the host's trusted keys.
        '';
      };
      uploadKeys = mkOption {
        type = types.listOf (types.submodule {
          options = {
            key = mkOption {
              type = sshKeyType;
              description = "SSH public key line of the CI push job.";
            };
            expires = mkOption {
              type = types.strMatching "[0-9]{8}";
              description = "Expiry (YYYYMMDD); sshd refuses the key afterwards and the pruner warns 14 days before.";
            };
          };
        });
        default = [];
        description = "Upload keys; list two during a rotation.";
      };
      maxBundleBytes = mkOption {
        type = types.ints.positive;
        default = gib 4;
        description = "Largest accepted upload (compressed).";
      };
      maxUnpackedBytes = mkOption {
        type = types.ints.positive;
        default = gib 8;
        description = "Largest accepted bundle after decompression.";
      };
      maxPending = mkOption {
        type = types.ints.positive;
        default = 16;
        description = "Bundles waiting beyond this many are rejected instead of filling the disk.";
      };
      sets = mkOption {
        type = types.nonEmptyListOf (types.strMatching "[a-z0-9][a-z0-9-]*");
        example = ["gate" "bump-flake-lock"];
        description = ''
          Set names (cache namespaces) this repo's bundles may pin under; a
          bundle naming any other set is rejected. No default: a bundle that
          carries no paths needs no signature, so this list is what bounds
          the namespaces an upload key can create (the latest pin of each
          active namespace is always kept).
        '';
      };
      maxRoots = mkOption {
        type = types.ints.positive;
        default = 64;
        description = ''
          Most roots one bundle may name; bundles naming more are rejected.
          Bounds what one upload can ask this host to substitute and pin.
        '';
      };
    };
  };

  defaultAlert = pkgs.writeShellScript "nix-cache-log-alert" ''
    # Default alert sink: the journal (tag nix-cache-alert). Set
    # services.nix-cache-host.alerts.command for push notifications.
    { printf '%s\n' "$1"; ${pkgs.coreutils}/bin/cat; } | ${pkgs.util-linux}/bin/logger -t nix-cache-alert
  '';
in {
  imports = [
    ./upload.nix
    ./importer.nix
    ./retention.nix
    ./read.nix
    ./alerts.nix
  ];

  options.services.nix-cache-host = {
    enable = lib.mkEnableOption "the self-hosted Nix binary cache host";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../../pkgs/nix-cache {};
      defaultText = lib.literalExpression "pkgs.callPackage <flake-playground>/nix/pkgs/nix-cache { }";
      description = "The nix-cache tooling (importer, pruner, receive script, alert spool).";
    };

    hostName = mkOption {
      type = types.str;
      example = "cache.example.org";
      description = "Public name of the cache vhost.";
    };

    htpasswdFile = mkOption {
      type = secretPath;
      description = ''
        htpasswd with one {SSHA} line per read token (create lines with
        nix-cache-htpasswd-entry). Must be readable by nginx. A string, not
        a path literal, so it never lands in the Nix store.
      '';
    };

    priority = mkOption {
      type = types.int;
      default = 50;
      description = "Priority advertised in nix-cache-info; cache.nixos.org is 40, so clients prefer it for upstream paths.";
    };

    harmonia.port = mkOption {
      type = types.port;
      default = 37450;
      description = "Loopback port Harmonia listens on (never exposed; nginx proxies to it).";
    };

    nginx = {
      useACMEHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "example.org";
        description = "Existing security.acme cert to serve; a wildcard keeps the cache name out of CT logs.";
      };
      sslCertificate = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "TLS certificate when not using useACMEHost.";
      };
      sslCertificateKey = mkOption {
        type = types.nullOr secretPath;
        default = null;
        description = "TLS key when not using useACMEHost (a string path outside the Nix store).";
      };
      defaultServer = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Add a host-wide nginx default server that rejects unknown TLS SNI
          and answers unknown Host headers with 444, so the cache name cannot
          be learned by connecting to the bare IP. Disable if the host already
          has a default server.
        '';
      };
      maxConnsPerUser = mkOption {
        type = types.ints.positive;
        default = 32;
        description = "Concurrent connections per token user.";
      };
      limitRate = mkOption {
        type = types.str;
        default = "0";
        example = "50m";
        description = "nginx limit_rate for NAR downloads, per connection; 0 is unlimited.";
      };
    };

    repos = mkOption {
      type = types.attrsOf (types.submodule repoModule);
      default = {};
      description = "CI repos allowed to push; one upload user and drop directory each.";
    };

    retention = {
      budgetBytes = mkOption {
        type = types.ints.positive;
        default = gib 50;
        description = "Union closure size the pruner keeps (shared paths counted once; the host's own system closure is free).";
      };
      activeDays = mkOption {
        type = types.ints.positive;
        default = 30;
        description = "A namespace whose newest pin is older than this loses the protection of its latest pin.";
      };
      protectHours = mkOption {
        type = types.ints.unsigned;
        default = 24;
        description = "Paths registered, or probed via narinfo, within this window are always kept.";
      };
      minFree = mkOption {
        type = types.ints.positive;
        default = gib 20;
        description = "nix min-free: the daemon collects unrooted paths when free space drops below this.";
      };
      maxFree = mkOption {
        type = types.ints.positive;
        default = gib 40;
        description = "nix max-free: how far such an emergency collection goes.";
      };
    };

    fail2ban.enable = mkOption {
      type = types.bool;
      default = config.services.fail2ban.enable;
      defaultText = lib.literalExpression "config.services.fail2ban.enable";
      description = "Ban IPs that try unknown token users (jail nix-cache-guess).";
    };

    alerts = {
      command = mkOption {
        type = alertCommandType;
        default = "${defaultAlert}";
        defaultText = lib.literalExpression "a script that logs to the journal with tag nix-cache-alert";
        description = ''
          Absolute path of one executable, run as COMMAND TITLE with the alert
          body on stdin. No arguments: wrap a command that needs them in a
          script (for example pkgs.writeShellScript).
        '';
      };
      loadCredential = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "LoadCredential entries the alert command needs (for example an ntfy token).";
      };
    };

    configFile = mkOption {
      type = types.path;
      readOnly = true;
      internal = true;
      description = "Generated JSON config read by cache-importer and cache-pruner.";
    };
  };

  config = lib.mkIf cfg.enable {
    # With allowed-users containing "*" (the NixOS default), every local
    # account, the upload users included, can talk to the nix-daemon. Not an
    # assertion: the host may accept that, but it should be a decision.
    warnings = lib.optional (lib.elem "*" (config.nix.settings.allowed-users or [])) ''
      services.nix-cache-host: nix.settings.allowed-users contains "*", so the
      cache-drop-* upload users can reach the nix-daemon. Set
      nix.settings.allowed-users to the accounts that need it (the module adds
      nix-cache and harmonia through extra-allowed-users).
    '';

    assertions =
      [
        {
          assertion = cfg.nginx.useACMEHost != null || (cfg.nginx.sslCertificate != null && cfg.nginx.sslCertificateKey != null);
          message = "services.nix-cache-host needs either nginx.useACMEHost or nginx.sslCertificate + nginx.sslCertificateKey";
        }
        {
          assertion = lib.allUnique (lib.mapAttrsToList (_: r: r.uid) cfg.repos);
          message = "services.nix-cache-host.repos: every repo needs a distinct uid";
        }
      ]
      ++ lib.mapAttrsToList (name: _: {
        assertion = builtins.match "[a-z0-9][a-z0-9-]*" name != null && builtins.stringLength "cache-drop-${name}" <= 32;
        message = "services.nix-cache-host.repos.${name}: name must match [a-z0-9][a-z0-9-]* and cache-drop-<name> must fit in 32 characters";
      })
      cfg.repos;

    users.users.nix-cache = {
      isSystemUser = true;
      group = "nix-cache";
      home = "/var/lib/nix-cache";
    };
    users.groups.nix-cache = {};

    nix.settings = {
      # extra-*: extend the host's lists instead of replacing them. Both users
      # stay untrusted, so the daemon still checks every signature.
      extra-allowed-users = ["nix-cache" "harmonia"];
      extra-trusted-public-keys = lib.concatMap (r: r.signingPublicKeys) (lib.attrValues cfg.repos);
      min-free = lib.mkDefault cfg.retention.minFree;
      max-free = lib.mkDefault cfg.retention.maxFree;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/nix-cache 0750 nix-cache nix-cache -"
      "d /var/lib/nix-cache/alerts 0700 nix-cache nix-cache -"
      "d /var/lib/nix-cache/alerts-deferred 0700 nix-cache nix-cache -"
      "d /var/lib/nix-cache/work 0700 nix-cache nix-cache -"
      # Created here, not by whoever locks first: cache-gc's flock(1) runs as
      # root and would leave a root-owned file the importer cannot open.
      "f /var/lib/nix-cache/lock 0600 nix-cache nix-cache -"
      "d /nix/var/nix/gcroots/cache 0755 nix-cache nix-cache -"
      "d /nix/var/nix/gcroots/cache/pins 0755 nix-cache nix-cache -"
    ];

    services.nix-cache-host.configFile = pkgs.writeText "nix-cache.json" (builtins.toJSON {
      state_dir = "/var/lib/nix-cache";
      gcroots_dir = "/nix/var/nix/gcroots/cache";
      access_log = "/var/log/nginx/nix-cache.access.log";
      budget_bytes = cfg.retention.budgetBytes;
      active_days = cfg.retention.activeDays;
      protect_hours = cfg.retention.protectHours;
      system_roots = ["/run/current-system" "/run/booted-system"];
      repos =
        lib.mapAttrs (name: r: {
          drop_dir = "/srv/cache-drop/${name}";
          trusted_keys = r.signingPublicKeys;
          max_bundle_bytes = r.maxBundleBytes;
          max_unpacked_bytes = r.maxUnpackedBytes;
          max_pending = r.maxPending;
          max_roots = r.maxRoots;
          allowed_sets = r.sets;
          upload_key_expiry = map (k: k.expires) r.uploadKeys;
        })
        cfg.repos;
    });

    # Lets an operator run the tools by hand with the live config, e.g.
    #   systemd-run --wait --pipe -p User=nix-cache -p SupplementaryGroups=nginx \
    #     -p Environment=PATH=/run/current-system/sw/bin \
    #     cache-pruner --config /etc/nix-cache/config.json --dry-run
    # (transient units get no `nix` on PATH otherwise).
    environment.etc."nix-cache/config.json".source = cfg.configFile;
    environment.systemPackages = [cfg.package];
  };
}
