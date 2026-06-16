{ fetchFromGitHub, vimUtils, vimPlugins }:
let
  inherit (vimUtils) buildVimPlugin;
in rec {
  # nvzone plugins live on `main` (rolling). volt is the shared runtime that
  # minty and menu require.
  volt = buildVimPlugin {
    pname = "volt";
    version = "2025-09-13";
    src = fetchFromGitHub {
      owner = "nvzone";
      repo = "volt";
      rev = "620de1321f275ec9d80028c68d1b88b409c0c8b1";
      hash = "sha256-5Xao1+QXZOvqwCXL6zWpckJPO1LDb8I7wtikMRFQ3Jk=";
    };
  };

  minty = buildVimPlugin {
    pname = "minty";
    version = "2025-02-28";
    src = fetchFromGitHub {
      owner = "nvzone";
      repo = "minty";
      rev = "aafc9e8e0afe6bf57580858a2849578d8d8db9e0";
      hash = "sha256-jdz0cR1uz1EdxFCuxndsK9gyTZ2jg8wdYA0v33SevOg=";
    };
    dependencies = [ volt ];
  };

  menu = buildVimPlugin {
    pname = "menu";
    version = "2025-06-01";
    src = fetchFromGitHub {
      owner = "nvzone";
      repo = "menu";
      rev = "7a0a4a2896b715c066cfbe320bdc048091874cc6";
      hash = "sha256-4GfQ6Mo32rsoQAXKZF9Bpnm/sms2hfbrTldpLp5ySoY=";
    };
    # nvim-tree-lua kept for NvChad's nvimtree context-menu entries (current
    # menu HEAD only `require`s volt directly, but the default menu acts on
    # nvim-tree buffers).
    dependencies = [ volt vimPlugins.nvim-tree-lua ];
    # menus/neo-tree.lua is an optional neo-tree.nvim integration we don't
    # bundle; exclude just that module from nvim-require-check.
    nvimSkipModules = [ "menus.neo-tree" ];
  };

  # NvChad v2.5 line. The core (NvChad/NvChad) is the piece that regressed on
  # neovim 0.12 - older revs used removed APIs (vim.tbl_islist, the legacy
  # nvim-treesitter configs.setup, etc.). v2.5 HEAD (2026-04-13) dropped them.
  # ui/base46 v2.5 are stable and already 0.12-clean. See ./NOTES.md.
  base46 = vimPlugins.base46.overrideAttrs (old: {
    version = "2.5-unstable-2025-01-17";
    src = fetchFromGitHub {
      inherit (old.src) owner repo;
      rev = "fde7a2cd54599e148d376f82980407c2d24b0fa2";
      hash = "sha256-Pw/tH69xkk0+HKiWSbTHsBIR904IGDO48TlufM1rkoM=";
    };
  });

  # ui stays at this rev: it's NEWER than the current v2.5 branch tip (NvChad
  # reset v2.5 backward) and the older tip fails nixpkgs' nvim-require-check
  # (nvchad.nvdash.init). This rev builds, is 0.12-clean, and pairs with the
  # updated core. See ./NOTES.md.
  nvchad-ui = vimPlugins.nvchad-ui.overrideAttrs (old: {
    version = "2.5-unstable-2025-01-15";
    src = fetchFromGitHub {
      inherit (old.src) owner repo;
      rev = "adcc97d7c7b97d3527a31338615751d2503fe0a4";
      hash = "sha256-lwFWqJy0yR/wGOF3T2yO9ZiIuBTIGcWr06G0510G+/k=";
    };
    # tabufline/modules.lua require("nvconfig") - nvconfig is your runtime
    # NvChad config, never present at build time. Append (don't replace) the
    # base derivation's skip list, which already covers the other nvconfig-only
    # modules (term, themes, cheatsheet, ...).
    nvimSkipModules = (old.nvimSkipModules or [ ]) ++ [ "nvchad.tabufline.modules" ];
    # Redirect base46 theme discovery from lazy.nvim's data path to our packDir
    # location. Done as substituteInPlace (not a .patch) so it survives
    # surrounding-context churn; --replace-fail trips loudly if upstream changes
    # the line (e.g. ui v3.0 computes this path dynamically and needs no patch).
    postPatch = ''
      substituteInPlace lua/nvchad/utils.lua \
        --replace-fail \
          'vim.fn.stdpath "data" .. "/lazy/base46/lua/base46/themes"' \
          'vim.fn.stdpath "config" .. "/lazyPlugins/pack/lazyPlugins/start" .. "/base46/lua/base46/themes"'
    '';
  });

  nvchad = vimPlugins.nvchad.overrideAttrs (old: {
    version = "2.5-unstable-2026-04-13";
    src = fetchFromGitHub {
      inherit (old.src) owner repo;
      rev = "d042cc975247c2aa55fcb228e5d146dc1dc6c648";
      hash = "sha256-WNQMaM5EQBRQC9JfvEIgFhn3K5n8q0YeiJ9NdG3E+z4=";
    };
    # nix-specific plugin-name fixes (nixpkgs ships these as `luasnip` and
    # `nvchad-ui`); still present in v2.5 HEAD's lua/nvchad/plugins/init.lua.
    postPatch = ''
      substituteInPlace lua/nvchad/plugins/init.lua \
        --replace-fail '"L3MON4D3/LuaSnip"' '"L3MON4D3/luasnip"' \
        --replace-fail '"nvchad/ui",' '"nvchad/ui", name = "nvchad-ui",'
    '';
  });

  # one handle that pulls in the whole NvChad set
  all = [ nvchad nvchad-ui base46 minty volt menu ];
}
