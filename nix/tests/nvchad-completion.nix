# Runtime test for programs.nvchad.completion: boot headless neovim with
# lazy.nvim resolving every plugin from the module's own lazyPlugins packdir
# (as a starter with `dev.path` pointed at it does), import `nvchad.plugins`,
# and assert which completion engine lazy.nvim resolved for each switch value.
# In both modes it also fails if any enabled plugin in the resolved spec has no
# directory in the packdir, i.e. lazy.nvim would have tried to clone it.
{
  pkgs,
  home-manager,
  homeManagerModules,
}: let
  inherit (pkgs) lib;
  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      homeManagerModules.nvchad
      {
        home.username = "ci";
        home.homeDirectory = "/home/ci";
        home.stateVersion = "25.11";
        programs.nvchad.enable = true;
      }
    ];
  };
  # The module's plugin list, minus withAllGrammars' 300+ grammar derivations
  # (not what this asks, and uncached; see nvim-loads.nix): swap it for the
  # grammar-less plugin, which has the same packdir name.
  lazyPlugins =
    builtins.filter (p: lib.getName p != "nvim-treesitter") hm.config.programs.nvchad.lazyPlugins
    ++ [pkgs.vimPlugins.nvim-treesitter];
  packdir = pkgs.vimUtils.packDir {lazyPlugins.start = lazyPlugins;};
  devPath = "${packdir}/pack/lazyPlugins/start";

  # Minimal user config: NvChad ui requires `chadrc` when it loads.
  userLua = pkgs.writeTextDir "lua/chadrc.lua" ''
    return { base46 = { theme = "onedark" } }
  '';

  probe = mode: expectOn: expectOff:
    pkgs.writeText "nvchad-completion-${mode}.lua" ''
      vim.g.nvchad_completion = "${mode}"
      vim.g.base46_cache = vim.fn.stdpath("data") .. "/base46/"
      vim.g.mapleader = " "
      vim.opt.rtp:prepend("${pkgs.vimPlugins.lazy-nvim}")
      vim.opt.rtp:prepend("${userLua}")
      require("lazy").setup({
        { "NvChad/NvChad", name = "nvchad", lazy = false, import = "nvchad.plugins" },
      }, {
        dev = { path = "${devPath}", patterns = { "" }, fallback = false },
        install = { missing = false },
        change_detection = { enabled = false },
        checker = { enabled = false },
        rocks = { enabled = false },
      })

      local plugins = require("lazy.core.config").plugins
      local errs = {}
      if not plugins["${expectOn}"] then
        table.insert(errs, "${expectOn} not in the resolved spec")
      end
      if plugins["${expectOff}"] then
        table.insert(errs, "${expectOff} still enabled")
      end
      for name, p in pairs(plugins) do
        if not vim.uv.fs_stat(p.dir) then
          table.insert(errs, name .. " has no packdir entry (" .. p.dir .. ")")
        end
      end
      -- Load the engine for real: blink's Rust matcher / cmp's setup must work.
      local ok, err = pcall(function() require("lazy").load({ plugins = { "${expectOn}" } }) end)
      if not ok then table.insert(errs, "loading ${expectOn}: " .. tostring(err)) end

      local out = assert(io.open(os.getenv("RESULT"), "w"))
      out:write(#errs == 0 and "OK\n" or ("FAIL\n" .. table.concat(errs, "\n") .. "\n"))
      out:close()
      vim.cmd("qall!")
    '';

  run = mode: on: off: ''
    echo "== completion = ${mode}"
    export RESULT="$PWD/${mode}.txt"
    timeout 120 nvim --headless -u ${probe mode on off} 2> ${mode}.err || true
    cat ${mode}.err
    if [ ! -f "$RESULT" ]; then echo "probe for ${mode} never finished" >&2; exit 1; fi
    cat "$RESULT"
    [ "$(head -n1 "$RESULT")" = OK ] || exit 1
  '';
in
  pkgs.runCommand "nvchad-completion" {nativeBuildInputs = [pkgs.neovim-unwrapped pkgs.git];} ''
    export HOME=$(mktemp -d)
    ${run "nvim-cmp" "nvim-cmp" "blink.cmp"}
    ${run "blink-cmp" "blink.cmp" "nvim-cmp"}
    echo "nvchad-completion: PASS"
    touch $out
  ''
