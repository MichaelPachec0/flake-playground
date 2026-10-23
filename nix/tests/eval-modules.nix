# CI harness: evaluate every NixOS / home-manager module by ENABLING it in a
# throwaway configuration and forcing full evaluation of the resulting system,
# WITHOUT building the (multi-GB) system closure.
#
# The `.drvPath` trick: interpolating a derivation's `.drvPath` into a string
# forces Nix to evaluate the entire module config (every `config` line, all
# assertions) to learn the path. `unsafeDiscardOutputDependency` is what keeps
# it cheap -- a bare `.drvPath` carries a DrvDeep context (`allOutputs = true`,
# check with `builtins.getContext`), so realising the runCommand would build the
# whole system closure. Discarding the output dependency leaves `path = true`:
# the .drv must exist, its outputs need not. Full eval, near-zero build cost.
#
# A module's real logic lives behind `lib.mkIf cfg.enable`, so each check must
# ENABLE the module (and supply any options that have no default) to exercise it.
{
  lib,
  pkgs,
  system,
  home-manager,
  nixosModules,
  homeManagerModules,
}: let
  # Minimal base config so a NixOS system evaluates. boot.isContainer = true
  # sidesteps the bootloader / fileSystems assertions.
  nixosStub = {
    boot.isContainer = true;
    system.stateVersion = "25.11";
    nixpkgs.config.allowUnfree = true;
  };

  # Shared base for the nix-cache-host checks. Secret paths are plain strings
  # (the module rejects path literals); eval never reads them.
  nixCacheHostCfg = {
    # Explicit, as on selene: the NixOS default ["*"] makes the module warn.
    nix.settings.allowed-users = ["@wheel"];
    services.nix-cache-host = {
      enable = true;
      hostName = "cache.example";
      htpasswdFile = "/run/secrets/nix-cache-htpasswd";
      nginx.sslCertificate = "/run/secrets/cert.pem";
      nginx.sslCertificateKey = "/run/secrets/key.pem";
      repos.flake-playground = {
        uid = 2001;
        signingPublicKeys = ["vmtest-repo-1:PKOUrEE06/Lg0wbDuGrjHbhekffk1kRlBPaYXDA/hc4="];
        sets = ["gate" "bump-flake-lock"];
        uploadKeys = [
          {
            key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVtZXN0IGtleSBmb3IgZXZhbCBjaGVja3Mgb25seQ ci";
            expires = "20991231";
          }
        ];
      };
    };
  };

  # Minimal base config so a home-manager generation evaluates.
  hmStub = {
    home.username = "ci";
    home.homeDirectory = "/home/ci";
    home.stateVersion = "25.11";
  };

  # Enable `nixosModules.<name>` with `enableCfg`, force eval of toplevel.
  evalNixos = name: enableCfg: let
    sys = lib.nixosSystem {
      inherit system;
      modules = [nixosModules.${name} nixosStub enableCfg];
    };
  in
    pkgs.runCommand "eval-nixos-${name}" {} ''
      echo "${builtins.unsafeDiscardOutputDependency sys.config.system.build.toplevel.drvPath}" > $out
    '';

  # Like evalNixos, but also fail the check unless `check sys.config` is true.
  # `checkName` names the derivation, so several checks of one module stay
  # distinguishable in build logs.
  # `deps` (strings with store-path context) are real build inputs of the check,
  # so small derivations named there get built (e.g. to run their shellcheck).
  evalNixosAssert = checkName: name: enableCfg: {
    check,
    message,
    deps ? (_: []),
  }: let
    sys = lib.nixosSystem {
      inherit system;
      modules = [nixosModules.${name} nixosStub enableCfg];
    };
  in
    assert lib.assertMsg (check sys.config) "${name}: ${message}";
      pkgs.runCommand "eval-${checkName}" {} ''
        echo "${builtins.unsafeDiscardOutputDependency sys.config.system.build.toplevel.drvPath}" > $out
        ${lib.concatMapStrings (d: "echo ${d} >> $out\n") (deps sys.config)}
      '';

  # Enable `homeManagerModules.<name>` with `enableCfg`, force eval of the
  # activation package.
  evalHome = name: enableCfg: let
    cfg = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [homeManagerModules.${name} hmStub enableCfg];
    };
  in
    pkgs.runCommand "eval-hm-${name}" {} ''
      echo "${builtins.unsafeDiscardOutputDependency cfg.activationPackage.drvPath}" > $out
    '';

  # Eval `nixosModules.<name>` with `cfg` and require that some assertion
  # FAILS with a message containing `needle`. Reads config.assertions directly,
  # so the failing config never has to evaluate a toplevel.
  expectAssertion = checkName: name: cfg: needle: let
    sys = lib.nixosSystem {
      inherit system;
      modules = [nixosModules.${name} nixosStub cfg];
    };
    failed = builtins.filter (a: !a.assertion) sys.config.assertions;
  in
    assert lib.assertMsg (builtins.any (a: lib.hasInfix needle a.message) failed)
    "${checkName}: expected a failing assertion containing '${needle}'";
      pkgs.runCommand "eval-assert-${checkName}" {} "touch $out";
in {
  nixos-cynthion = evalNixos "cynthion" {hardware.cynthion.enable = true;};
  nixos-realsense = evalNixos "realsense" {hardware.realsense.enable = true;};
  nixos-zsa = evalNixos "zsa" {
    hardware.zsa.wally.enable = true;
    hardware.zsa.oryx.enable = true;
    hardware.zsa.legacy.enable = true;
  };
  nixos-hyprpolkitagent = evalNixos "hyprpolkitagent" {services.hyprpolkitagent.enable = true;};
  nixos-tuwunel = evalNixos "tuwunel" {
    services.tuwunel.enable = true;
    services.tuwunel.settings.global.server_name = "ci.example";
  };
  nixos-windscribe = evalNixos "windscribe" {services.windscribe.enable = true;};
  # flushRuleset = true deletes the helper's `inet windscribe` table on every
  # nftables reload: the module must warn and add the re-apply unit. A stub
  # package keeps the heavy Windscribe build out of the gate while the re-apply
  # script itself is built, so its shellcheck runs here.
  # A stop flushes too (ExecStop replays `flush ruleset`), so nftables gets an
  # ExecStopPost that enqueues the on-stop unit, which must not RemainAfterExit
  # (it has to return to inactive to be re-triggered by the next stop).
  nixos-windscribe-nft-flush = let
    stub = pkgs.runCommand "windscribe-stub" {} "mkdir -p $out/bin";
    enqueue = "start --no-block windscribe-nft-reapply-onstop.service";
  in
    evalNixosAssert "nixos-windscribe-nft-flush" "windscribe" {
      services.windscribe.enable = true;
      services.windscribe.package = stub;
      services.windscribe.addUsersToGroup = ["alice"];
      networking.nftables.enable = true;
      networking.nftables.flushRuleset = true;
    } {
      check = c:
        lib.any (lib.hasInfix "windscribe-nft-reapply.service") c.warnings
        && c.systemd.services ? windscribe-nft-reapply
        && lib.any (lib.hasInfix enqueue) (c.systemd.services.nftables.serviceConfig.ExecStopPost or [])
        && c.systemd.services ? windscribe-nft-reapply-onstop
        && !(c.systemd.services.windscribe-nft-reapply-onstop.serviceConfig.RemainAfterExit or false);
      message = "flushRuleset = true must warn, define windscribe-nft-reapply and the on-stop unit (no RemainAfterExit), and enqueue it from nftables ExecStopPost";
      deps = c: [c.systemd.services.windscribe-nft-reapply.serviceConfig.ExecStart];
    };
  nixos-windscribe-nft-noflush =
    evalNixosAssert "nixos-windscribe-nft-noflush" "windscribe" {
      services.windscribe.enable = true;
      networking.nftables.enable = true;
      networking.nftables.flushRuleset = false;
    } {
      check = c:
        !(lib.any (lib.hasInfix "windscribe-nft-reapply") c.warnings)
        && !(c.systemd.services ? windscribe-nft-reapply)
        && !(c.systemd.services ? windscribe-nft-reapply-onstop)
        && !(c.systemd.services.nftables.serviceConfig ? ExecStopPost);
      message = "flushRuleset = false must neither warn, define the re-apply units, nor add an nftables ExecStopPost";
    };
  # Without nftables, flushRuleset is irrelevant: no warning, no re-apply units,
  # and no nftables.service conjured up by the ExecStopPost hook.
  nixos-windscribe-no-nftables =
    evalNixosAssert "nixos-windscribe-no-nftables" "windscribe" {
      services.windscribe.enable = true;
      networking.nftables.enable = false;
      networking.nftables.flushRuleset = true;
    } {
      check = c:
        !(lib.any (lib.hasInfix "windscribe-nft-reapply") c.warnings)
        && !(c.systemd.services ? windscribe-nft-reapply)
        && !(c.systemd.services ? windscribe-nft-reapply-onstop)
        && !(c.systemd.services ? nftables);
      message = "nftables disabled must neither warn, define the re-apply units, nor define nftables.service";
    };
  nixos-affine = evalNixos "affine" {
    services.affine.enable = true;
    services.affine.externalUrl = "https://ci.example";
  };
  nixos-mcp-affine = evalNixos "mcp" {
    mcp.affine.enable = true;
    mcp.affine.baseUrl = "https://ci.example";
    # path literals; eval never reads them (LoadCredential is a runtime concern)
    mcp.affine.emailFile = "/run/secrets/affine-email";
    mcp.affine.passwordFile = "/run/secrets/affine-password";
    mcp.affine.http.allowUnauthenticated = true;
  };

  nixos-picr = evalNixos "picr" {
    services.picr.enable = true;
    services.picr.baseUrl = "https://ci.example/";
  };

  nixos-picr-secrets = evalNixos "picr" {
    services.picr.enable = true;
    services.picr.baseUrl = "https://ci.example/";
    services.picr.database.manage = false;
    services.picr.database.host = "db.example";
    # path literals; eval never reads them (LoadCredential is a runtime concern)
    services.picr.database.passwordFile = "/run/secrets/picr-db";
    services.picr.tokenSecretFile = "/run/secrets/picr-token";
    services.picr.admin.passwordFile = "/run/secrets/picr-admin";
    services.picr.pingTokenFile = "/run/secrets/picr-ping";
    services.picr.nginx.enable = true;
    services.picr.nginx.hostName = "photos.example.com";
    security.acme.acceptTerms = true;
    security.acme.defaults.email = "ci@example.com";
  };

  nixos-picr-ping = evalNixos "picr" {
    services.picr.ping.enable = true;
    services.picr.ping.picrUrl = "https://ci.example/";
    services.picr.ping.tokenFile = "/run/secrets/picr-ping-token";
    services.picr.ping.watchRoot = "/srv/media";
  };
  nixos-projectsend = evalNixos "projectsend" {
    services.projectsend.enable = true;
    services.projectsend.appUrl = "https://ci.example";
    services.projectsend.nginx.hostName = "ci.example";
    services.projectsend.database.createLocally = true;
  };

  nixos-pingvin-share = evalNixos "pingvin-share" {
    services.pingvin-share-x.enable = true;
    services.pingvin-share-x.nginx.enable = true;
    services.pingvin-share-x.nginx.hostName = "ci.example";
    services.pingvin-share-x.settings.general.appUrl = "https://ci.example";
    # Path literal; eval never reads it (LoadCredential is runtime-only).
    services.pingvin-share-x.secrets."smtp.password" = "/run/secrets/pingvin-smtp";
    # nginx.enable turns on enableACME/forceSSL, which assert ToS
    # acceptance (same as nixos-picr-secrets below).
    security.acme.acceptTerms = true;
    security.acme.defaults.email = "ci@example.com";
  };

  # Also covers the optional group rule, which is the branch that grows the
  # generated udev file beyond the plain uaccess line.
  nixos-arduino-flasher-cli = evalNixos "arduino-flasher-cli" {
    programs.arduino-flasher-cli.enable = true;
    programs.arduino-flasher-cli.group = "plugdev";
  };

  nixos-zipline-extras = evalNixos "zipline-extras" {
    services.zipline.enable = true;
    services.zipline-extras.enable = true;
  };
  nixos-zipline-extras-cutover = evalNixos "zipline-extras" {
    services.zipline.enable = true;
    services.zipline.database.createLocally = false;
    services.zipline-extras.enable = true;
    services.zipline-extras.experimental.migrateToPglite.enable = true;
  };
  nixos-zipline-extras-assert-zipline = expectAssertion "zipline-extras-zipline" "zipline-extras" {
    services.zipline-extras.enable = true;
  } "requires services.zipline.enable";
  nixos-zipline-extras-assert-cutover-local = expectAssertion "zipline-extras-cutover-local" "zipline-extras" {
    services.zipline.enable = true;
    services.zipline-extras.enable = true;
    services.zipline-extras.experimental.migrateToPglite.enable = true;
  } "requires services.zipline.database.createLocally = false";
  nixos-zipline-extras-assert-cutover-url = expectAssertion "zipline-extras-cutover-url" "zipline-extras" {
    services.zipline.enable = true;
    services.zipline.database.createLocally = false;
    services.zipline.settings.DATABASE_URL = "pglite:///var/lib/zipline/data";
    services.zipline-extras.enable = true;
    services.zipline-extras.experimental.migrateToPglite.enable = true;
  } "migrateToPglite writes to";

  nixos-nix-cache-host = evalNixosAssert "nixos-nix-cache-host" "nix-cache-host" nixCacheHostCfg {
    check = c: let
      keys = c.users.users.cache-drop-flake-playground.openssh.authorizedKeys.keys;
    in
      lib.hasInfix "ForceCommand" c.services.openssh.extraConfig
      && lib.hasInfix "Match User cache-drop-flake-playground\n  AcceptEnv NIX_CACHE_UPLOAD_NO_ENV\n" c.services.openssh.extraConfig
      && lib.hasSuffix "Match all\n" c.services.openssh.extraConfig
      && lib.all (k: lib.hasPrefix "restrict,command=" k && lib.hasInfix "expiry-time=\"20991231\"" k) keys
      && c.users.users.cache-drop-flake-playground.uid == 2001
      && lib.elem "nix-cache" c.nix.settings.extra-allowed-users
      && lib.elem "harmonia" c.nix.settings.extra-allowed-users
      && lib.any (lib.hasInfix "A+ /srv/cache-drop/flake-playground/incoming") c.systemd.tmpfiles.rules
      && lib.hasInfix "ip46tables -w -A nix-cache-egress -m owner --uid-owner 2001 -j DROP" c.networking.firewall.extraCommands
      && !(lib.any (lib.hasInfix "allowed-users") c.warnings)
      && c.environment.etc ? "nix-cache/config.json"
      && c.systemd.paths ? cache-importer-flake-playground
      && c.systemd.services.cache-importer-flake-playground.serviceConfig.PrivateNetwork
      && c.systemd.services.cache-pruner.unitConfig.OnSuccess == ["cache-gc.service"]
      && c.systemd.timers ? cache-pruner
      && lib.hasInfix "nix-store --gc" c.systemd.services.cache-gc.serviceConfig.ExecStart
      && lib.hasInfix "flock /var/lib/nix-cache/lock " c.systemd.services.cache-gc.serviceConfig.ExecStart
      && !(c.systemd.services.cache-gc.serviceConfig ? User)
      && c.systemd.paths ? nix-cache-alert
      && c.systemd.paths.nix-cache-alert.pathConfig.PathExistsGlob == "/var/lib/nix-cache/alerts/*.json"
      && !(c.systemd.paths.nix-cache-alert.pathConfig ? DirectoryNotEmpty)
      && c.systemd.services ? "nix-cache-unit-failed@"
      # Glob, not DirectoryNotEmpty: files the importer leaves in incoming/
      # would re-trigger the path unit until its start limit trips.
      && c.systemd.paths.cache-importer-flake-playground.pathConfig.PathExistsGlob == "/srv/cache-drop/flake-playground/incoming/*.tar.zst"
      && !(c.systemd.paths.cache-importer-flake-playground.pathConfig ? DirectoryNotEmpty)
      && c.systemd.services.cache-importer-flake-playground.unitConfig.OnFailure == ["nix-cache-unit-failed@%n.service"]
      && lib.elem c.nix.package c.systemd.services.cache-pruner.path
      && lib.elem c.nix.package c.systemd.services.cache-importer-flake-playground.path
      && lib.all (s: lib.elem "/nix/var/nix/gcroots/cache" c.systemd.services.${s}.serviceConfig.ReadWritePaths) ["cache-pruner" "cache-importer-flake-playground"]
      # All three hold the shared lock: a hung run must time out and alert.
      && c.systemd.services.cache-importer-flake-playground.serviceConfig.TimeoutStartSec == "2h"
      && c.systemd.services.cache-pruner.serviceConfig.TimeoutStartSec == "3h"
      && c.systemd.services.cache-gc.serviceConfig.TimeoutStartSec == "1h"
      && lib.elem "f /var/lib/nix-cache/lock 0600 nix-cache nix-cache -" c.systemd.tmpfiles.rules
      && c.services.harmonia.cache.enable
      && c.services.harmonia.cache.signKeyPaths == []
      && c.services.harmonia.cache.settings.bind == "127.0.0.1:37450"
      && c.services.nginx.virtualHosts."cache.example".basicAuthFile == "/run/secrets/nix-cache-htpasswd"
      # Outside the allowlist: 404 in the content phase, after auth (a
      # rewrite-phase `return` would answer anonymous probes before auth).
      && c.services.nginx.virtualHosts."cache.example".locations."/".return == null
      && c.services.nginx.virtualHosts."cache.example".locations."/".tryFiles == "/nix-cache-not-found =404"
      && lib.all (l: lib.hasInfix "limit_except GET { deny all; }" l.extraConfig && lib.hasInfix "Cache-Control \"private\" always" l.extraConfig)
      (map (n: c.services.nginx.virtualHosts."cache.example".locations.${n}) ["= /nix-cache-info" "~ \"^/[0-9a-df-np-sv-z]{32}\\.narinfo$\"" "^~ /nar/"])
      && c.services.nginx.virtualHosts.nix-cache-default-server.rejectSSL
      && lib.hasInfix "log_format nix_cache_json" c.services.nginx.commonHttpConfig
      # The pruner reads the access log through SupplementaryGroups = nginx.
      && c.users.groups ? ${c.services.nginx.group}
      # Rotation the pruner can follow: rename + reopen, <log>.1 uncompressed.
      && !(c.services.logrotate.settings.nginx.copytruncate or false)
      && c.services.logrotate.settings.nginx.delaycompress
      && !(c.services.logrotate.settings.header.dateext or false)
      # The importer's per-repo caps: allowed set names and roots per bundle.
      && (let
        repo = (builtins.fromJSON c.services.nix-cache-host.configFile.text).repos.flake-playground;
      in
        repo.allowed_sets == ["gate" "bump-flake-lock"] && repo.max_roots == 64);
    message = "upload user, sshd Match block (AcceptEnv reset), daemon access, drop dirs, iptables egress, importer/pruner/GC/alert units, Harmonia on loopback, the nginx vhost (GET-only, private, content-phase 404), default server, nginx group, log rotation, importer/pruner start timeouts and the importer's set allowlist and root cap must be configured, and an explicit allowed-users must not warn";
  };
  # fail2ban on: only the guess jail (unknown token users), with escalating
  # bans, and fail2ban waits for nginx to create the error log.
  nixos-nix-cache-host-fail2ban =
    evalNixosAssert "nixos-nix-cache-host-fail2ban" "nix-cache-host" (lib.recursiveUpdate nixCacheHostCfg {
      services.fail2ban.enable = true;
    }) {
      check = c: let
        jail = c.services.fail2ban.jails.nix-cache-guess;
      in
        jail.settings.logpath
        == "/var/log/nginx/nix-cache.error.log"
        && jail.settings."bantime.increment"
        && lib.hasPrefix "^\\s*\\[error\\] " jail.filter.Definition.failregex
        # Colon-free user match: ".*" or ".*?" would let a forged Referer pick <HOST>.
        && lib.hasInfix "user \"[^:]*\" was not found in \"[^\"]*\", client: <HOST>, server: \\S*, request: " jail.filter.Definition.failregex
        && lib.filter (lib.hasPrefix "nix-cache") (lib.attrNames c.services.fail2ban.jails) == ["nix-cache-guess"]
        && lib.elem "nginx.service" c.systemd.services.fail2ban.after;
      message = "with fail2ban enabled the module must add only the nix-cache-guess jail (anchored failregex, bantime.increment) and order fail2ban after nginx";
    };
  # nftables branch of the egress block. The nftables start script is a build
  # input, so the ruleset also goes through `nft --check` here.
  nixos-nix-cache-host-nftables =
    evalNixosAssert "nixos-nix-cache-host-nftables" "nix-cache-host" (lib.recursiveUpdate nixCacheHostCfg {
      networking.nftables.enable = true;
    }) {
      check = c:
        lib.hasInfix "meta skuid { 2001 } counter drop" c.networking.nftables.tables.nix-cache-egress.content
        && c.networking.firewall.extraCommands == "";
      message = "with nftables the egress drop must be an nftables table (no iptables commands)";
      deps = c: lib.toList c.systemd.services.nftables.serviceConfig.ExecStart;
    };
  # The NixOS default allowed-users = ["*"] lets the upload users reach the
  # daemon: warn. Reads config.warnings only (no toplevel), so the gate log
  # stays free of the warning text.
  nixos-nix-cache-host-warns-allowed-users = let
    sys = lib.nixosSystem {
      inherit system;
      modules = [nixosModules.nix-cache-host nixosStub nixCacheHostCfg {nix.settings.allowed-users = lib.mkForce ["*"];}];
    };
  in
    assert lib.assertMsg (lib.any (lib.hasInfix "allowed-users contains \"*\"") sys.config.warnings)
    "nix-cache-host: allowed-users containing \"*\" must produce a warning";
      pkgs.runCommand "eval-assert-nixos-nix-cache-host-warns-allowed-users" {} "touch $out";
  nixos-nix-cache-host-needs-tls = expectAssertion "nixos-nix-cache-host-needs-tls" "nix-cache-host" {
    services.nix-cache-host = {
      enable = true;
      hostName = "cache.example";
      htpasswdFile = "/run/secrets/nix-cache-htpasswd";
    };
  } "needs either nginx.useACMEHost";
  nixos-nix-cache-host-no-user-env = expectAssertion "nixos-nix-cache-host-no-user-env" "nix-cache-host" (lib.recursiveUpdate nixCacheHostCfg {
    services.openssh.settings.PermitUserEnvironment = "BASH_ENV";
  }) "PermitUserEnvironment must stay disabled";
  # Option types that keep secrets out of the store and keep authorized_keys
  # to one restricted line per key: each override must fail to evaluate.
  nixos-nix-cache-host-rejects-unsafe-input = let
    rejectsIn = base: override: sel: let
      sys = lib.nixosSystem {
        inherit system;
        modules = [nixosModules.nix-cache-host nixosStub base override];
      };
    in
      !(builtins.tryEval (builtins.deepSeq (sel sys.config.services.nix-cache-host) true)).success;
    rejects = rejectsIn nixCacheHostCfg;
    # The base config without repos.flake-playground.sets (it has no default).
    withoutSets = lib.recursiveUpdate (removeAttrs nixCacheHostCfg ["services"]) {
      services.nix-cache-host =
        nixCacheHostCfg.services.nix-cache-host
        // {repos.flake-playground = removeAttrs nixCacheHostCfg.services.nix-cache-host.repos.flake-playground ["sets"];};
    };
    sets = h: h.repos.flake-playground.sets;
    signing = h: h.repos.flake-playground.signingPublicKeys;
    badSets = v: {services.nix-cache-host.repos.flake-playground.sets = lib.mkForce v;};
    badKey = key: {
      services.nix-cache-host.repos.flake-playground.uploadKeys = [
        {
          inherit key;
          expires = "20991231";
        }
      ];
    };
    keys = h: h.repos.flake-playground.uploadKeys;
    good = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVtZXN0IGtleSBmb3IgZXZhbCBjaGVja3Mgb25seQ";
  in
    assert lib.assertMsg (
      rejects (badKey "${good} ci\n${good} injected") keys
      && rejects (badKey "command=\"/bin/sh\" ${good}") keys
      && rejects (badKey "AAAAC3NzaC1lZDI1NTE5") keys
      && rejects {services.nix-cache-host.htpasswdFile = lib.mkForce ./eval-modules.nix;} (h: h.htpasswdFile)
      && rejects {services.nix-cache-host.htpasswdFile = lib.mkForce "${builtins.storeDir}/x-htpasswd";} (h: h.htpasswdFile)
      && rejects {services.nix-cache-host.htpasswdFile = lib.mkForce "relative/htpasswd";} (h: h.htpasswdFile)
      && rejects {services.nix-cache-host.nginx.sslCertificateKey = lib.mkForce ./eval-modules.nix;} (h: h.nginx.sslCertificateKey)
      && rejects {services.nix-cache-host.alerts.command = "/bin/notify --token x";} (h: h.alerts.command)
      && rejects {services.nix-cache-host.alerts.command = "/bin/notify%n";} (h: h.alerts.command)
      && rejects {services.nix-cache-host.alerts.command = "/bin/a;b";} (h: h.alerts.command)
      && rejects {services.nix-cache-host.alerts.command = "notify";} (h: h.alerts.command)
      && !(rejects {services.nix-cache-host.alerts.command = "/run/current-system/sw/bin/ntfy-alert";} (h: h.alerts.command))
      && rejects {services.nix-cache-host.repos.flake-playground.signingPublicKeys = lib.mkForce [];} signing
      && rejects {services.nix-cache-host.repos.flake-playground.signingPublicKeys = lib.mkForce ["nocolon"];} signing
      && rejects {services.nix-cache-host.repos.flake-playground.signingPublicKeys = lib.mkForce ["k-1:AA AA"];} signing
      && rejects {services.nix-cache-host.repos.flake-playground.signingPublicKeys = lib.mkForce ["k-1:AAAA\n"];} signing
      && rejectsIn withoutSets {} sets
      && rejects (badSets []) sets
      && rejects (badSets ["Gate"]) sets
      && rejects (badSets ["a/b"]) sets
      && rejects (badSets ["-gate"]) sets
      && rejects {services.nix-cache-host.repos.flake-playground.maxRoots = 0;} (h: h.repos.flake-playground.maxRoots)
      && !(rejects {} (h: [(keys h) (sets h) (signing h) h.htpasswdFile h.nginx.sslCertificateKey h.alerts.command]))
    ) "nix-cache-host: upload keys with newlines/options/no type, store or path-literal secrets, alert commands that are not one absolute path, empty or malformed signing keys, and missing, empty or malformed repo set lists must be rejected";
      pkgs.runCommand "eval-assert-nixos-nix-cache-host-rejects-unsafe-input" {} "touch $out";

  # uploadKeys.*.expires must be a real calendar date, not just 8 digits.
  nixos-nix-cache-host-rejects-bad-expiry = let
    failing = expires: let
      sys = lib.nixosSystem {
        inherit system;
        modules = [
          nixosModules.nix-cache-host
          nixosStub
          nixCacheHostCfg
          {services.nix-cache-host.repos.flake-playground.uploadKeys = lib.mkForce [(builtins.head nixCacheHostCfg.services.nix-cache-host.repos.flake-playground.uploadKeys // {inherit expires;})];}
        ];
      };
    in
      lib.any (a: !a.assertion && lib.hasInfix "expires \"${expires}\" is not a real date" a.message) sys.config.assertions;
  in
    assert lib.assertMsg (
      lib.all failing ["20991399" "20990001" "20990100" "20990230" "20990431" "20991132" "20990229" "21000229"]
      && !(lib.any failing ["20991231" "20280229" "20000229" "20990131" "20990430"])
    ) "nix-cache-host: an uploadKeys expiry with an impossible month or day must fail an assertion, real dates must not";
      pkgs.runCommand "eval-assert-nixos-nix-cache-host-rejects-bad-expiry" {} "touch $out";

  hm-nvchad = evalHome "nvchad" {programs.nvchad.enable = true;};
  hm-cspell = evalHome "cspell" {programs.cspell.enable = true;};
}
