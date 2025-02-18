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
    linux-show-player = pkgs.callPackage ./nix/linux-show-player.nix {};
    # windscribe = {
    #   cli = pkgs.callPackage ./nix/windscribe/cli.nix {};
    # };
    cynthion = pkgs.callPackage ./nix/cynthion {};
    memtimings-linux = pkgs.callPackage ./nix/memtimings-linux {};
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
    nixosModules.default = import ./nix/module.nix inputs;
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
