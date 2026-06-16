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

  # NvChad set: the core stays on v2.5 (the only repo that regressed on neovim
  # 0.12 - v2.5 HEAD 2026-04-13 dropped vim.tbl_islist / the legacy
  # nvim-treesitter configs.setup), while ui + base46 track the v3.0 line. The
  # v2.5 core and v3.0 ui/base46 are verified compatible on 0.12 (the prior ui
  # pin adcc97d was itself an early v3.0-line commit). See ./NOTES.md.
  base46 = vimPlugins.base46.overrideAttrs (old: {
    version = "3.0-unstable-2026-01-16";
    src = fetchFromGitHub {
      inherit (old.src) owner repo;
      rev = "884b990dcdbe07520a0892da6ba3e8d202b46337";
      hash = "sha256-AUdBZbGcPDtixHMFms9Y0EyUdAXOzvcA2AbrRdYQ4ig=";
    };
  });

  # ui on the v3.0 tip. v3.0 resolves the base46 themes path dynamically
  # (debug.getinfo on the loaded base46 module), so it needs no theme-path
  # patch, and the base derivation's nvimSkipModules already covers its
  # nvconfig-only modules - hence a minimal override.
  nvchad-ui = vimPlugins.nvchad-ui.overrideAttrs (old: {
    version = "3.0-unstable-2026-05-10";
    src = fetchFromGitHub {
      inherit (old.src) owner repo;
      rev = "3e67e9d5325fd47fdbc90ca00a147db2f3525754";
      hash = "sha256-bl2erzyZCZp9seb4E7o/SFsBUHwocVOmQNv0mbO5yR0=";
    };
  });

  nvchad = vimPlugins.nvchad.overrideAttrs (old: {
    version = "2.5-unstable-2026-04-13";
    src = fetchFromGitHub {
      inherit (old.src) owner repo;
      rev = "d042cc975247c2aa55fcb228e5d146dc1dc6c648";
      hash = "sha256-WNQMaM5EQBRQC9JfvEIgFhn3K5n8q0YeiJ9NdG3E+z4=";
    };
    # Core d042cc9 uses the NEW nvim-treesitter API
    # (require("nvim-treesitter").install / .setup via lazy), so it must NOT get
    # nixpkgs' default nvim-treesitter-legacy dependency. Hardcode the dep list
    # (mirrors nixpkgs' nvchad deps with legacy -> nvim-treesitter) so the
    # deprecated legacy plugin is never referenced. Update if nixpkgs changes
    # nvchad's deps. Grammars are supplied by the module's lazyPlugins.
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
