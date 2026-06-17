{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types literalExpression;
  cfg = config.programs.nvchad;

  # The packaged NvChad set (v2.5 core + v3.0 ui/base46 + nvzone). See
  # ../../../pkgs/nvchad. nvchad.all = [ nvchad nvchad-ui base46 minty volt menu ].
  nvchad = pkgs.callPackage ../../../pkgs/nvchad { };

  # Grammar parsers for the rtp:append hack below. The NEW main-branch
  # nvim-treesitter - NvChad core d042cc9 uses its .install/.setup API, and the
  # nvchad package swaps its legacy dep for this one.
  treesitterDeps = pkgs.symlinkJoin {
    name = "treesitter-dependencies";
    paths = pkgs.vimPlugins.nvim-treesitter.withAllGrammars.dependencies;
  };
in {
  options.programs.nvchad = {
    enable = mkEnableOption "NvChad";

    package = mkOption {
      type = types.package;
      default = pkgs.neovim-unwrapped;
      defaultText = literalExpression "pkgs.neovim-unwrapped";
      description = ''
        The (unwrapped) neovim package, fed to programs.neovim.package. Also used
        to strip neovim's bundled treesitter parsers from the runtimepath: they
        live in ''${package}/lib/nvim and clash with the grammars we ship.
      '';
    };

    lazyPlugins = mkOption {
      type = with types; listOf package;
      default =
        (with pkgs.vimPlugins; [
          cmp-async-path
          cmp-buffer
          cmp-nvim-lsp
          cmp-nvim-lua
          cmp-path
          cmp_luasnip
          comment-nvim
          friendly-snippets
          gitsigns-nvim
          indent-blankline-nvim
          luasnip
          nvim-autopairs
          nvim-cmp
          nvim-colorizer-lua
          nvim-lspconfig
          nvim-tree-lua
          nvim-web-devicons
          nvterm
          telescope-nvim
          which-key-nvim
          # NvChad's default config uses these
          better-escape-nvim
          conform-nvim
          # NEW nvim-treesitter (NvChad core d042cc9 calls its .install/.setup
          # API). The nvchad package swaps its legacy dep for this, so there is
          # no "two versions of nvim-treesitter" packDir clash.
          nvim-treesitter.withAllGrammars
        ])
        # base46, nvchad-ui, nvchad, minty, volt, menu - our pinned set.
        ++ nvchad.all;
      defaultText = literalExpression "<NvChad plugin set>";
      description = ''
        Neovim plugins required by NvChad, made available to lazy.nvim's local
        plugins search path (~/.config/nvim/lazyPlugins/pack/lazyPlugins/start).
        Normally you don't need to change this option.
      '';
    };

    extraEarlyPlugins = mkOption {
      type = with types; listOf package;
      default = [ ];
      example = literalExpression ''
        with pkgs.vimPlugins; [
          fidget-nvim
        ]
      '';
      description = ''
        Extra plugins to load along with the usual nvchad ones. These are NOT
        lazy loaded (they go on programs.neovim.plugins), so use sparingly.
      '';
    };

    extraLazyPlugins = mkOption {
      type = with types; listOf package;
      default = [ ];
      example = literalExpression ''
        with pkgs.vimPlugins; [
          neogit
          null-ls-nvim
        ]
      '';
      description = ''
        Extra plugins added to lazy.nvim's local search path. If you follow
        <https://nvchad.com/docs/config/plugins> to set up additional plugins,
        use this to avoid lazy.nvim downloading them.
      '';
    };

    extraEarlyConfig = mkOption {
      type = types.lines;
      default = "";
      example = "vim.g.mapleader = ' '";
      description = ''
        Lua placed EARLY in the generated ~/.config/nvim/init.lua - before
        extraConfig (and before the treesitter rtp:append postlude). For leader
        keys, options, anything that must run before your plugin bootstrap.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = literalExpression "builtins.readFile ./nv/init.lua";
      description = ''
        Lua placed in the generated ~/.config/nvim/init.lua, after
        extraEarlyConfig. Put your NvChad starter's init bootstrap here (lazy
        setup, requires, ...). home-manager manages init.lua from initLua, so do
        not also place your own ~/.config/nvim/init.lua - it would collide. Your
        starter's lua/ modules are require-able if placed at ~/.config/nvim/lua,
        e.g. xdg.configFile."nvim/lua".source = ./nv/lua;
      '';
    };
  };

  config = mkIf cfg.enable {
    xdg.configFile."nvim/lazyPlugins".source = pkgs.vimUtils.packDir {
      lazyPlugins = {
        start = cfg.lazyPlugins ++ cfg.extraLazyPlugins;
      };
    };

    # Replaces the old programs.nixneovim wrapper with home-manager's stock
    # programs.neovim. init.lua is assembled as a \n-joined list of strings
    # (home-manager's initLua is types.lines): the treesitter rtp prelude and
    # postlude bracket your extraEarlyConfig/extraConfig, and the rtp:append
    # must stay last (lazy.nvim clears rtp). extraEarlyPlugins -> non-lazy
    # plugins; extraPackages carries ripgrep.
    programs.neovim = {
      enable = true;
      package = cfg.package;
      extraPackages = [ pkgs.ripgrep ];
      plugins = [ nvchad.base46 pkgs.vimPlugins.lazy-nvim ] ++ cfg.extraEarlyPlugins;
      initLua = lib.concatStringsSep "\n" [
        ''
          -- HACK: remove the default nvim parsers, they clash with treesitter.
          vim.opt.rtp:remove("${cfg.package}/lib/nvim")
        ''
        cfg.extraEarlyConfig
        cfg.extraConfig
        ''
          -- HACK: make sure treesitter's grammar parsers are in view. lazy.nvim
          -- clears rtp by default, so this must be appended last.
          vim.opt.rtp:append("${treesitterDeps}")
        ''
      ];
    };
  };
}
