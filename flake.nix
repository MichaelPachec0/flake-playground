{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    inherit (self) outputs;
    # NOTE: for now this has only been tested with x86_64-linux.
    # TODO: adapt this a better flake style, there better written flakes out there.
    # For now though this works.
    system = "x86_64-linux";
    prepNixpkgs = _nixpkgs: system:
      import _nixpkgs {
        config.allowUnfree = true;
        inherit system;
      };
    pkgs = prepNixpkgs nixpkgs system;
    linux-show-player = pkgs.callPackage ./nix/pkgs/linux-show-player.nix {};
    # windscribe = {
    #   cli = pkgs.callPackage ./nix/pkgs/windscribe/cli.nix {};
    # };
    cynthion = pkgs.callPackage ./nix/pkgs/cynthion {};
    memtimings-linux = pkgs.callPackage ./nix/pkgs/memtimings-linux {};
  in {
    packages = {x86_64-linux = {inherit linux-show-player cynthion memtimings-linux;};};
    overlays = let
      playground = final: prev: {
        playground = {inherit linux-show-player cynthion;};
      };
    in {
      inherit playground;
      default = playground;
    };
    nixosModules = let
      cynthion = import ./nix/modules/cynthion inputs;
      realsense = import ./nix/modules/realsense inputs;
      zsa = import ./nix/modules/zsa inputs;
    in {
      inherit cynthion realsense zsa;
      # default = pkgs.lib.mkMerge [cynthion realsense zsa];

      default = import ./nix/modules inputs;
    };
    devShells.x86_64-linux = {
      cynthion =
        pkgs.mkShell {packages = [cynthion];};
      linux-show-player =
        pkgs.mkShell {packages = with pkgs; [linux-show-player];};
      memtimings-linux = pkgs.mkShell {packages = [memtimings-linux];};
      # windscribe = let
      #   cli = with pkgs; [dpkg openvpn stunnel];
      #   desktop = with pkgs; [];
      # in {
      #   default = pkgs.mkShell {packages = cli ++ desktop;};
      #   cli = pkgs.mkShell {packages = cli;};
      #   desktop = pkgs.mkShell {packages = desktop;};
      # };
    };
  };
}
