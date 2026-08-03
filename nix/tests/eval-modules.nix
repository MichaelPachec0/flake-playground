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

  # Units a bare stub system already has. Anything a module adds on top is its
  # own, and is worth realising (see evalNixos). Evaluated once and shared.
  baseUnits = builtins.attrNames (lib.nixosSystem {
    inherit system;
    modules = [nixosStub];
  })
  .config.systemd.units;

  # Enable `nixosModules.<name>` with `enableCfg` and force eval of toplevel.
  #
  # `evalNixosUnits` additionally BUILDS the units the module itself contributes
  # (the stub system's units are subtracted out). That covers what pure eval
  # cannot: writeShellScript syntax-checks its script, and the packages a unit
  # references must be substitutable or buildable -- a stale npmDepsHash is
  # caught here rather than at deploy time. It is opt-in, and stays opt-in,
  # because how much a unit drags in is not obvious from the module:
  #
  #   mcp     -> 3 drvs   (unit + its writeShellScript wrapper)
  #   tuwunel -> 3 drvs
  #   polkit  -> 15 drvs + 105 paths, because polkit.service references
  #              config.system.path, which pulls system-path and the nixos-*
  #              tools with it
  #   affine / windscribe -> the ~1GB OCI image and the heavy C++ build that
  #              flake.nix deliberately keeps out of the CI aggregates
  #
  # So: check `nix build --dry-run` before opting a module in, and leave it on
  # the plain `evalNixos` if the answer is anything but small.
  mkEvalNixos = {buildUnits ? false}: name: enableCfg: let
    sys = lib.nixosSystem {
      inherit system;
      modules = [nixosModules.${name} nixosStub enableCfg];
    };
    ownUnits =
      lib.optionals buildUnits
      (lib.attrValues (lib.mapAttrs (_: u: u.unit) (removeAttrs sys.config.systemd.units baseUnits)));
  in
    pkgs.runCommand "eval-nixos-${name}" {} ''
      echo "${builtins.unsafeDiscardOutputDependency sys.config.system.build.toplevel.drvPath}" > $out
      ${lib.concatMapStringsSep "\n" (u: "echo ${u} >> $out") ownUnits}
    '';

  evalNixos = mkEvalNixos {};
  evalNixosUnits = mkEvalNixos {buildUnits = true;};

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
  nixos-tuwunel = evalNixosUnits "tuwunel" {
    services.tuwunel.enable = true;
    services.tuwunel.settings.global.server_name = "ci.example";
  };
  nixos-windscribe = evalNixos "windscribe" {services.windscribe.enable = true;};
  nixos-affine = evalNixos "affine" {
    services.affine.enable = true;
    services.affine.externalUrl = "https://ci.example";
  };
  nixos-mcp-affine = evalNixosUnits "mcp" {
    mcp.affine.enable = true;
    mcp.affine.baseUrl = "https://ci.example";
    # path literals; eval never reads them (LoadCredential is a runtime concern)
    mcp.affine.emailFile = "/run/secrets/affine-email";
    mcp.affine.passwordFile = "/run/secrets/affine-password";
    mcp.affine.http.allowUnauthenticated = true;
  };

  hm-nvchad = evalHome "nvchad" {programs.nvchad.enable = true;};
  hm-cspell = evalHome "cspell" {programs.cspell.enable = true;};
}
