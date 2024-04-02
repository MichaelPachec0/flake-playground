{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    inherit (self) outputs;
    system = "x86_64-linux";
    prepNixpkgs = _nixpkgs: system:
      import _nixpkgs {
        config.allowUnfree = true;
        inherit system;
      };
    pkgs = prepNixpkgs nixpkgs system;
    test-build = pkgs.callPackage ./nix/linux-show-player.nix {};
  in {
    packages = {
      # x86_64-linux.default = linux-show-player;
      x86_64-linux.default = test-build;
    };
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [
        test-build
      ];
    };
  };
}
