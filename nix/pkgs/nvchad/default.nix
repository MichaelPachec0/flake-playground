{ callPackage, vimUtils, vimPlugins }:
let
  inherit (vimUtils) buildVimPlugin;
  # Sources are nvfetcher-tracked alongside the custom vim plugins
  # (../vimPlugins/nvfetcher.toml), each tracking NvChad's stable branch: core
  # v2.5, ui + base46 v3.0, nvzone main. The daily bump only lands if the full
  # check set (incl. nvim-loads and nvchad-deps) passes. version is the commit
  # date, prefixed with the branch for the NvChad repos.
  sources = callPackage ../vimPlugins/_sources/generated.nix { };
in rec {
  # nvzone plugins live on `main` (rolling). volt is the shared runtime that
  # minty and menu require.
  volt = buildVimPlugin {
    pname = "volt";
    version = sources.volt.date;
    inherit (sources.volt) src;
  };

  minty = buildVimPlugin {
    pname = "minty";
    version = sources.minty.date;
    inherit (sources.minty) src;
    dependencies = [ volt ];
  };

  menu = buildVimPlugin {
    pname = "menu";
    version = sources.menu.date;
    inherit (sources.menu) src;
    # nvim-tree-lua and neo-tree-nvim back menu's two file-tree context menus
    # (the default menu acts on nvim-tree buffers; menus/neo-tree.lua requires
    # neo-tree.sources.*). Shipping neo-tree lets nvim-require-check cover that
    # integration instead of skipping it. nvim-require-check only puts direct
    # dependencies on the path, so neo-tree's own nui/plenary are listed too.
    dependencies = [ volt ] ++ (with vimPlugins; [
      nvim-tree-lua
      neo-tree-nvim
      nui-nvim
      plenary-nvim
    ]);
  };

  # NvChad set: the core tracks v2.5 (NvChad's stable branch; there is no v3.0
  # core yet), while ui + base46 track v3.0, the branch core v2.5 pulls them
  # from (it pins no branch and v3.0 is their default). The mix is verified
  # compatible on neovim 0.12. See ./NOTES.md.
  base46 = vimPlugins.base46.overrideAttrs (old: {
    version = "3.0-unstable-${sources.base46.date}";
    inherit (sources.base46) src;
    # nixpkgs' base46 depends on nixpkgs' nvchad-ui; point it at ours so the
    # closure holds one stable-tracked nvchad-ui (two same-named plugins would
    # collide in the packdir).
    dependencies = [ nvchad-ui ];
  });

  # ui v3.0 resolves the base46 themes path dynamically
  # (debug.getinfo on the loaded base46 module), so it needs no theme-path
  # patch, and the base derivation's nvimSkipModules already covers its
  # nvconfig-only modules.
  nvchad-ui = vimPlugins.nvchad-ui.overrideAttrs (old: {
    version = "3.0-unstable-${sources.nvchadUi.date}";
    inherit (sources.nvchadUi) src;
    # Our tracked volt, not nixpkgs' nvzone-volt (same packdir name).
    dependencies = [ volt ];
    # ui ships an opt-in blink.cmp spec (`{ import = "nvchad.blink.lazyspec" }`
    # replaces nvim-cmp); give its LuaSnip the nixpkgs plugin name, as the core
    # postPatch does.
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lua/nvchad/blink/lazyspec.lua \
        --replace-fail '"L3MON4D3/LuaSnip"' '"L3MON4D3/luasnip"'
    '';
  });

  nvchad = vimPlugins.nvchad.overrideAttrs (old: {
    version = "2.5-unstable-${sources.nvchad.date}";
    inherit (sources.nvchad) src;
    # Core v2.5 uses the NEW nvim-treesitter API
    # (require("nvim-treesitter").install / .setup via lazy), so it must NOT get
    # nixpkgs' default nvim-treesitter-legacy dependency. Hardcode the dep list
    # (mirrors nixpkgs' nvchad deps with legacy -> nvim-treesitter) so the
    # deprecated legacy plugin is never referenced. Update if nixpkgs changes
    # nvchad's deps. Grammars are supplied by the module's lazyPlugins. The
    # nvchad-deps check catches a core bump that asks for a plugin we lack.
    dependencies = (with vimPlugins; [
      gitsigns-nvim
      luasnip
      mason-nvim
      nvim-cmp
      nvim-lspconfig
      telescope-nvim
      nvim-treesitter
    ]) ++ [ nvchad-ui ];
    # nix-specific plugin-name fixes (nixpkgs ships these as `luasnip` and
    # `nvchad-ui`). --replace-fail makes a bump that moves these specs fail
    # the build instead of silently shipping unresolvable names.
    # nix-completion.lua is the switch behind programs.nvchad.completion: lazy's
    # `import = "nvchad.plugins"` loads every module in that directory, so this
    # file pulls in ui's blink.cmp spec (which disables nvim-cmp) whenever
    # vim.g.nvchad_completion == "blink-cmp", with no change to the starter.
    postPatch = ''
      cat > lua/nvchad/plugins/nix-completion.lua <<'EOF'
      return {
        {
          import = "nvchad.blink.lazyspec",
          enabled = function()
            return vim.g.nvchad_completion == "blink-cmp"
          end,
        },
      }
      EOF
      substituteInPlace lua/nvchad/plugins/init.lua \
        --replace-fail '"L3MON4D3/LuaSnip"' '"L3MON4D3/luasnip"' \
        --replace-fail '"nvchad/ui",' '"nvchad/ui", name = "nvchad-ui",'
    '';
  });

  # one handle that pulls in the whole NvChad set
  all = [ nvchad nvchad-ui base46 minty volt menu ];
}
