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

  hm-nvchad = evalHome "nvchad" {programs.nvchad.enable = true;};
  hm-cspell = evalHome "cspell" {programs.cspell.enable = true;};
}
