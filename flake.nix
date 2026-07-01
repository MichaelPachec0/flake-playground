{
  inputs = {
    # Branch strategy (see README.md):
    #   main/master -> nixos-unstable  (neovim 0.12+, latest pkgs)
    #   stable      -> nixos-25.11     (neovim 0.11.x)
    # old nixpkgs
    # github:NixOS/nixpkgs/0b73e36b1962620a8ac551a37229dd8662dac5c8?narHash=sha256-wjWLzdM7PIq4ZAe7k3vyjtgVJn6b0UeodtRFlM/6W5U%3D
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pyproject-nix = {
      url = "github:nix-community/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Dictionary packs for the cspell home-manager module (plain source tree).
    cspell-dicts = {
      url = "github:streetsidesoftware/cspell-dicts";
      flake = false;
    };
    # Eval-only: lets CI evaluate the home-manager modules (hm-nvchad, hm-cspell)
    # via home-manager.lib.homeManagerConfiguration. follows nixpkgs to avoid a
    # second nixpkgs in the closure.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    self,
    nixpkgs,
    pyproject-nix,
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
    # Windscribe carries its own overlay (ECH-patched openssl/curl, static spdlog with
    # external fmt, c-ares), so build it against a pkgs with that overlay applied. The
    # package is self-contained: it fetches the Windscribe Desktop source (v2.23.9) and
    # its Go/prebuilt deps itself. `devMode = false` is the hardened production build the
    # NixOS module consumes.
    windscribePkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [ (import ./nix/pkgs/windscribe/overlay.nix) ];
    };
    windscribe = import ./nix/pkgs/windscribe {
      pkgs = windscribePkgs;
      devMode = false;
    };
    cynthion = pkgs.callPackage ./nix/pkgs/cynthion {};
    memtimings-linux = pkgs.callPackage ./nix/pkgs/memtimings-linux {};
    ryzen-monitor-ng = pkgs.callPackage ./nix/pkgs/ryzen-monitor-ng {};
    ursh = pkgs.callPackage ./nix/pkgs/ursh {};
    urchin = pkgs.callPackage ./nix/pkgs/ursh/urchin.nix {inherit pyproject-nix;};
    llcat = pkgs.callPackage ./nix/pkgs/ursh/llcat.nix {inherit pyproject-nix;};
    nvchadPlugins = pkgs.callPackage ./nix/pkgs/nvchad {};
    # custom neovim plugins (nvfetcher-tracked) + the headless-nvim load test.
    customVimPlugins = import ./nix/pkgs/vimPlugins {inherit pkgs;};
    nvimLoads = import ./nix/tests/nvim-loads.nix {inherit pkgs;};
    # third-party packages tracked at latest upstream via nvfetcher
    # (nix/pkgs/playground) -- exposed under the `playground` attrset.
    playgroundPkgs = import ./nix/pkgs/playground {inherit pkgs;};
    # The first-class package set. Factored into a let-binding so both
    # `packages.x86_64-linux` and the `packages` check can consume it (DRY).
    mainPackages = {
      inherit
        linux-show-player
        cynthion
        memtimings-linux
        ryzen-monitor-ng
        ursh
        urchin
        llcat
        ;
      inherit (nvchadPlugins) nvchad nvchad-ui base46 minty volt menu;
    };
    # Per-module eval checks (enable + evaluate each module). See
    # nix/tests/eval-modules.nix. Attr names: nixos-* and hm-*.
    moduleChecks = import ./nix/tests/eval-modules.nix {
      lib = nixpkgs.lib;
      inherit pkgs system;
      home-manager = inputs.home-manager;
      nixosModules = self.nixosModules;
      homeManagerModules = self.homeManagerModules;
    };
  in {
    # windscribe is exposed for on-demand `nix build .#windscribe` but kept OUT of
    # mainPackages so the heavy C++ build doesn't run in the packages/default CI aggregates.
    # The NixOS module is still eval-checked (nixos-windscribe) via the cheap .drvPath trick.
    packages.x86_64-linux = mainPackages // { inherit windscribe; };

    # Nested trees; build one with e.g.
    #   nix build .#legacyPackages.x86_64-linux.vimPlugins.wtf-nvim
    #   nix build .#legacyPackages.x86_64-linux.playground.workstyle
    legacyPackages.x86_64-linux = {
      vimPlugins = customVimPlugins;
      playground = playgroundPkgs;
    };

    # CI gate (see .github/workflows). `vimplugins` builds every custom plugin
    # (each runs its own nvim-require-check); `nvim-loads` boots headless nvim
    # with the whole set. The daily nvfetcher bump only commits if these pass.
    checks.x86_64-linux =
      {
        nvim-loads = nvimLoads;
        vimplugins = pkgs.linkFarmFromDrvs "vimplugins" (builtins.attrValues customVimPlugins);
        playground = pkgs.linkFarmFromDrvs "playground" (builtins.attrValues playgroundPkgs);
        # Build every first-class package. This is the coverage that was missing:
        # nothing under packages.x86_64-linux was built in CI before.
        packages = pkgs.linkFarmFromDrvs "packages" (builtins.attrValues mainPackages);
        # Aggregate of EVERYTHING, so `nix build .#checks.x86_64-linux.default`
        # exercises the full surface locally even without nix-fast-build.
        default = pkgs.linkFarmFromDrvs "checks-default" (
          (builtins.attrValues customVimPlugins)
          ++ (builtins.attrValues playgroundPkgs)
          ++ (builtins.attrValues mainPackages)
          ++ (builtins.attrValues moduleChecks)
          ++ [nvimLoads]
        );
      }
      // moduleChecks;
    overlays = let
      playground = final: prev: {
        playground =
          {
            inherit linux-show-player cynthion ryzen-monitor-ng ursh urchin llcat;
            # nvchad set: pkgs.playground.nvchad.{nvchad,nvchad-ui,base46,minty,volt,menu,all}
            nvchad = nvchadPlugins;
          }
          # nvfetcher-tracked latest-upstream packages: pkgs.playground.workstyle, ...
          // playgroundPkgs;
      };
      # Inject the migrated custom vim plugins into pkgs.vimPlugins. Drop-in for
      # nix-config's old `local` overlay, so `pkgs.vimPlugins.<name>` keeps
      # resolving for consumers.
      vimPlugins = final: prev: {
        vimPlugins = prev.vimPlugins // (import ./nix/pkgs/vimPlugins {pkgs = prev;});
      };
    in {
      inherit playground vimPlugins;
      default = playground;
    };
    nixosModules = let
      cynthion = import ./nix/modules/nixos/cynthion inputs;
      realsense = import ./nix/modules/nixos/realsense inputs;
      zsa = import ./nix/modules/nixos/zsa inputs;
      hyprpolkitagent = import ./nix/modules/nixos/hyprpolkitagent;
      tuwunel = import ./nix/modules/nixos/tuwunel inputs;
      windscribe = import ./nix/modules/nixos/windscribe inputs;
    in {
      inherit cynthion realsense zsa hyprpolkitagent tuwunel windscribe;
      # default imports every NixOS module under nix/modules/nixos.
      default = import ./nix/modules/nixos inputs;
    };
    homeManagerModules = let
      nvchad = import ./nix/modules/home-manager/nvchad;
      cspell = import ./nix/modules/home-manager/cspell inputs;
    in {
      inherit nvchad cspell;
      # default imports every home-manager module under nix/modules/home-manager.
      default = import ./nix/modules/home-manager inputs;
    };
    devShells.x86_64-linux = {
      # `nix develop` -> nvfetcher for regenerating nix/pkgs/vimPlugins/_sources.
      default = pkgs.mkShell {packages = [pkgs.nvfetcher pkgs.python3];};
      cynthion =
        pkgs.mkShell {packages = [cynthion];};
      linux-show-player =
        pkgs.mkShell {packages = with pkgs; [linux-show-player];};
      memtimings-linux = pkgs.mkShell {packages = [memtimings-linux];};
      ryzen-monitor-ng = pkgs.mkShell {
        inputsFrom = [ryzen-monitor-ng];
        shellHook = ''
          echo "📦 Ready to debug phases"
          echo "Run: configurePhase, buildPhase, installPhase, etc."
        '';
      };
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
