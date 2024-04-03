{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, ... }@inputs:
    let
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
      linux-show-player = pkgs.callPackage ./nix/linux-show-player.nix { };
    in {
      packages = { x86_64-linux = { inherit linux-show-player; }; };
      overlays = let
        playground = final: prev: {
          playground = { inherit linux-show-player; };
        };
      in {
        inherit playground;
        default = playground;
      };
      devShells.x86_64-linux = {
        linux-show-player =
          pkgs.mkShell { packages = with pkgs; [ linux-show-player ]; };
      };
    };
}
