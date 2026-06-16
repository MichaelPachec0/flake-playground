{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types literalExpression;
  cfg = config.programs.nvchad;
  nvchad = pkgs.callPackage ../../pkgs/nvchad { };
in {
  options.programs.nvchad = {
    enable = mkEnableOption "NvChad plugin set + neovim (you manage init/config in ~/.config/nvim)";

    package = mkOption {
      type = types.package;
      default = pkgs.neovim;
      defaultText = literalExpression "pkgs.neovim";
      description = ''
        The neovim package to install. Pick whichever version/build you want
        (e.g. pkgs.neovim, a pinned neovim, or a custom wrapNeovim build).
      '';
    };

    lazyPlugins = mkOption {
      type = types.listOf types.package;
      default = nvchad.all;
      defaultText = literalExpression "nvchad.all  # base46, nvchad-ui, nvchad, minty, volt, menu";
      description = ''
        Plugins materialised into the lazy.nvim local search path
        (~/.config/nvim/lazyPlugins/pack/lazyPlugins/start). Defaults to the
        full NvChad set; override to swap pieces out.
      '';
    };

    extraLazyPlugins = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = literalExpression "[ pkgs.vimPlugins.nvim-treesitter.withAllGrammars ]";
      description = ''
        Extra plugins added to the lazy.nvim local search path, e.g. treesitter
        grammars or plugins you reference from your own NvChad config.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];
    xdg.configFile."nvim/lazyPlugins".source = pkgs.vimUtils.packDir {
      lazyPlugins.start = cfg.lazyPlugins ++ cfg.extraLazyPlugins;
    };
  };
}
