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

  nixos-zipline-latest = evalNixos "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.environmentFiles = ["/run/secrets/zipline.env"];
    services.zipline-latest.trustedProxies = ["127.0.0.1" "10.0.0.0/8"];
  };
  nixos-zipline-latest-import = evalNixos "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.experimental.importFromNixpkgs.enable = true;
  };
  nixos-zipline-latest-cutover = evalNixos "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.database.type = "pglite";
    services.zipline-latest.experimental.migrateToPglite.enable = true;
  };
  nixos-zipline-latest-pglite = evalNixos "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.database.type = "pglite";
  };
  # Both services keep DATABASE_URL only in environmentFiles: nothing known to
  # compare, so the shared-DB assertion must not fire.
  nixos-zipline-latest-env-file-db = evalNixos "zipline-latest" {
    services.zipline.enable = true;
    services.zipline.database.createLocally = false;
    services.zipline.environmentFiles = ["/run/secrets/zipline.env"];
    services.zipline-latest.enable = true;
    services.zipline-latest.database.createLocally = false;
    services.zipline-latest.environmentFiles = ["/run/secrets/zipline-latest.env"];
  };
  nixos-zipline-latest-assert-pglite-local = expectAssertion "zipline-latest-pglite-local" "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.database.type = "pglite";
    services.zipline-latest.database.createLocally = true;
  } "needs no local PostgreSQL";
  nixos-zipline-latest-assert-pglite-url = expectAssertion "zipline-latest-pglite-url" "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.database.type = "pglite";
    services.zipline-latest.settings.DATABASE_URL = "postgresql://x@localhost/x";
  } "requires settings.DATABASE_URL";
  nixos-zipline-latest-assert-shared-db = expectAssertion "zipline-latest-shared-db" "zipline-latest" {
    services.zipline.enable = true;
    # nixpkgs sets DATABASE_URL at normal priority when createLocally; turn it
    # off or the explicit value below is a definition conflict, not an assertion.
    services.zipline.database.createLocally = false;
    services.zipline.settings.DATABASE_URL = "postgresql://zipline-latest@localhost/zipline-latest?host=/run/postgresql";
    services.zipline-latest.enable = true;
  } "same DATABASE_URL";
  nixos-zipline-latest-assert-import = expectAssertion "zipline-latest-import" "zipline-latest" {
    services.zipline.enable = true;
    services.zipline-latest.enable = true;
    services.zipline-latest.experimental.importFromNixpkgs.enable = true;
  } "importFromNixpkgs requires";
  nixos-zipline-latest-assert-import-url = expectAssertion "zipline-latest-import-url" "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.experimental.importFromNixpkgs.enable = true;
    services.zipline-latest.settings.DATABASE_URL = "postgresql://x@localhost/x";
  } "importFromNixpkgs restores into";
  nixos-zipline-latest-assert-import-dir = expectAssertion "zipline-latest-import-dir" "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.experimental.importFromNixpkgs.enable = true;
    services.zipline-latest.settings.DATASOURCE_LOCAL_DIRECTORY = "/srv/uploads";
  } "importFromNixpkgs restores into";
  nixos-zipline-latest-assert-cutover = expectAssertion "zipline-latest-cutover" "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.experimental.migrateToPglite.enable = true;
  } "migrateToPglite requires";
  nixos-zipline-latest-assert-cutover-url = expectAssertion "zipline-latest-cutover-url" "zipline-latest" {
    services.zipline-latest.enable = true;
    services.zipline-latest.database.type = "pglite";
    services.zipline-latest.experimental.migrateToPglite.enable = true;
    services.zipline-latest.settings.DATABASE_URL = "pglite:///var/lib/zipline-latest/data";
  } "migrateToPglite writes to";

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

  hm-nvchad = evalHome "nvchad" {programs.nvchad.enable = true;};
  hm-cspell = evalHome "cspell" {programs.cspell.enable = true;};
}
