# Custom neovim plugins, migrated from nix-config's pkgs/vimPlugins. Sources are
# tracked by nvfetcher (./nvfetcher.toml -> ./_sources); only the per-plugin
# build metadata (deps, skipped modules, patches, build phases) lives here.
#
# Attribute names match what nix-config's overlay called them, so consuming this
# set as a `pkgs.vimPlugins` overlay is a drop-in replacement.
#
# Once both nvfetcher.toml and default.nix have a plugin set run nvfetch with
# the new plugin to create the needed code in _sources
# nix develop -c nvfetcher -c nix/pkgs/vimPlugins/nvfetcher.toml -o nix/pkgs/vimPlugins/_sources -f <plugin>
# where plugin is the name in nvfetcher.toml
{pkgs}: let
  inherit (pkgs) vimUtils vimPlugins luajitPackages;
  sources = pkgs.callPackage ./_sources/generated.nix {};

  # build <pname> <source> <extraAttrs> -> buildVimPlugin consuming an nvfetcher
  # source for src; version is the source's commit date for readability.
  build = pname: source: extra:
    vimUtils.buildVimPlugin ({
        inherit pname;
        inherit (source) src;
        version = source.date or source.version;
      }
      // extra);
in {
  block-nvim = build "block.nvim" sources.blockNvim {};

  clear-action-nvim = build "clear-action.nvim" sources.clearActionNvim {};

  coc-elixir = build "coc-elixir" sources.cocElixir {};

  coc-lightbulb = build "coc-lightbulb" sources.cocLightbulb {};

  cspell-nvim = build "cspell.nvim" sources.cspellNvim {
    dependencies = with vimPlugins; [plenary-nvim null-ls-nvim];
  };

  direnv-vim = build "direnv.vim" sources.direnvVim {};

  git-nvim = build "git.nvim" sources.gitNvim {};

  guihua-lua = build "guihua.lua" sources.guihuaLua {
    buildPhase = ''
      (
        cd lua/fzy
        make
      )
    '';
    # require("fzy.fzy-lua-native") loads a compiled .so via a relative path the
    # require-check can't resolve; ts_obsolete.highlight pulls a legacy
    # nvim-treesitter API that isn't present. Skip both.
    nvimSkipModules = ["fzy.fzy-lua-native" "guihua.ts_obsolete.highlight"];
    dependencies = with vimPlugins; [plenary-nvim nvim-treesitter];
  };

  indentmini = build "indentmini.nvim" sources.indentmini {};

  inlay-hints-nvim = build "inlay-hints.nvim" sources.inlayHints {};

  kitty-scrollback-nvim = build "kitty-scrollback.nvim" sources.kittyScrollback {};

  mini-move = build "mini.move" sources.miniMove {};

  neoai-nvim = build "neoai.nvim" sources.neoai {
    dependencies = with vimPlugins; [nui-nvim];
  };

  neotest-gtest = build "neotest-gtest" sources.neotestGtest {
    # ships a test lua file the require-check chokes on
    doCheck = false;
  };

  none-ls-extras-nvim = build "none-ls-extras-nvim" sources.noneLsExtras {
    doCheck = false;
    doInstallCheck = false;
  };

  none-ls-nvim = build "none-ls.nvim" sources.noneLs {
    # none-ls (null-ls fork) needs plenary on the rtp for its require-check.
    dependencies = with vimPlugins; [plenary-nvim];
    # these diagnostics builtins can't be required standalone (they reference
    # external linters); skip them in the check.
    nvimSkipModules = [
      "null-ls.builtins.diagnostics.sqruff"
      "null-ls.builtins.diagnostics.sqlfluff"
      "null-ls.builtins.diagnostics.kube_linter"
      "null-ls.builtins.diagnostics.phpmd"
      "null-ls.builtins.diagnostics.twigcs"
    ];
  };

  nvim-dap-repl-highlights = build "nvim-dap-repl-highlights" sources.nvimDapReplHighlights {
    meta = {
      description = "Add syntax highlighting to the nvim-dap REPL";
      homepage = "https://github.com/LiadOz/nvim-dap-repl-highlights";
    };
  };

  nvim-emmet = build "nvim-emmet" sources.nvimEmmet {};

  osv-nvim = build "one-small-step-for-vimkind" sources.oneSmallStep {};

  pfp-vim = build "pfp-vim" sources.pfpVim {};

  sg-nvim = build "sg.nvim" sources.sgNvim {
    dependencies = with vimPlugins; [plenary-nvim];
    # cody.fuzzy needs the native sg binary; the cmp/telescope extensions need
    # those optional deps. Skip them in the require-check (this is the lua side
    # only -- nix-config used inputs.sg for the full Rust-backed build).
    nvimSkipModules = ["sg.cody.fuzzy" "sg.extensions.cmp" "sg.extensions.telescope"];
  };

  stay-centered = build "stay-centered.nvim" sources.stayCentered {};

  telescope-docker-nvim = build "telescope-docker.nvim" sources.telescopeDocker {
    dependencies = with vimPlugins; [telescope-nvim plenary-nvim];
  };

  ts-software-licenses-nvim = build "telescope-software-licenses.nvim" sources.tsSoftwareLicenses {};

  vimBeGood = build "vim-be-good" sources.vimBeGood {};

  virt-column = build "virt-column.nvim" sources.virtColumn {
    nvimSkipModules = ["virt-column.config.types"];
    nativeBuildInputs = [luajitPackages.luacheck];
  };

  wtf-nvim = build "wtf.nvim" sources.wtfNvim {
    # runtime deps for the require-check. (nix-config patched the upstream test
    # harness to avoid cloning deps, but buildVimPlugin never runs tests/, so the
    # patch is unnecessary -- and it stopped applying once we track latest.)
    dependencies = with vimPlugins; [nui-nvim plenary-nvim];
  };
}
