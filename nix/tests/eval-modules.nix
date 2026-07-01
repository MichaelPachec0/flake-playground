# CI harness: evaluate every NixOS / home-manager module by ENABLING it in a
# throwaway configuration and forcing full evaluation of the resulting system,
# WITHOUT building the (multi-GB) system closure.
#
# The `.drvPath` trick: interpolating a derivation's `.drvPath` into a string
# carries only "this .drv must be instantiated" context (not "this output must
# be built"). So building each tiny `runCommand` forces Nix to evaluate the
# entire module config (every `config` line, all assertions) but never realises
# the system. Full eval, near-zero build cost.
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
      echo "${sys.config.system.build.toplevel.drvPath}" > $out
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
      echo "${cfg.activationPackage.drvPath}" > $out
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

  hm-nvchad = evalHome "nvchad" {programs.nvchad.enable = true;};
  hm-cspell = evalHome "cspell" {programs.cspell.enable = true;};
}
