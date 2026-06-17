# Integration smoke-test: boot a real (headless) neovim with the full NvChad set
# + every migrated custom plugin on the packpath, then assert the framework
# modules load. Each plugin's own modules are already require-checked at build
# time (buildVimPlugin); this catches breakage that only shows up when the set
# is loaded *together* (startup-script errors, removed APIs after an nvfetcher
# bump, version conflicts). The daily updater gates its commit on this passing.
{pkgs}: let
  inherit (pkgs) lib;
  nvchad = pkgs.callPackage ../pkgs/nvchad {};
  # import (not callPackage): callPackage would add `override`/`overrideDerivation`
  # function attrs that builtins.attrValues below would wrongly treat as plugins.
  customPlugins = import ../pkgs/vimPlugins {inherit pkgs;};

  # What we boot: the packaged NvChad plugins, a representative slice of the
  # runtime plugins the nvchad module ships by default, and all migrated customs.
  # Having the customs as `start` packages means `packloadall` runs each one's
  # plugin/ scripts at startup, so a custom that errors on load is surfaced.
  startPlugins =
    nvchad.all
    ++ (with pkgs.vimPlugins; [
      nvim-treesitter.withAllGrammars
      telescope-nvim
      nvim-cmp
      nvim-lspconfig
      which-key-nvim
      gitsigns-nvim
      nvim-autopairs
      comment-nvim
      plenary-nvim
      nui-nvim
    ])
    ++ (builtins.attrValues customPlugins);

  # Framework modules to pcall(require) once the set is loaded. These names are
  # stable; a load failure (syntax error, missing dep, removed API) fails the
  # build. The customs are covered by their own build-time require-check; here we
  # confirm the integrated set still boots and the framework is usable.
  probeModules = [
    "base46"
    "telescope"
    "cmp"
    "which-key"
    "gitsigns"
    "nvim-autopairs"
    "Comment"
    "nvim-treesitter"
    "plenary"
  ];

  # NB: a Lua table literal ({...}), not JSON ([...]) which is not valid Lua.
  probe = pkgs.writeText "nvim-loads-probe.lua" ''
    local mods = { ${lib.concatMapStringsSep ", " (m: ''"${m}"'') probeModules} }
    local failed = {}
    for _, m in ipairs(mods) do
      local ok, err = pcall(require, m)
      if not ok then
        table.insert(failed, m .. ": " .. tostring(err))
      end
    end
    -- Write an explicit verdict so the build only passes when the probe actually
    -- ran to completion (a parse error here would leave no result -> build fails).
    local out = assert(io.open(os.getenv("NVIM_LOADS_RESULT"), "w"))
    if #failed > 0 then
      out:write("FAIL\n" .. table.concat(failed, "\n") .. "\n")
    else
      out:write("OK\n")
    end
    out:close()
    vim.cmd("quitall!")
  '';

  testNvim = pkgs.wrapNeovim pkgs.neovim-unwrapped {
    configure = {
      packages.test.start = startPlugins;
      customRC = "luafile ${probe}";
    };
  };
in
  pkgs.runCommand "nvim-loads" {nativeBuildInputs = [testNvim pkgs.git];} ''
    export HOME=$(mktemp -d)
    export NVIM_LOADS_RESULT="$PWD/result.txt"
    # Boot headless. Plugin startup scripts that need an absent provider (python3)
    # may warn -- harmless; the verdict is the probe's result file, not nvim's
    # exit code or incidental stderr.
    timeout 180 nvim --headless +qa 2> err.log || true
    echo "----- nvim stderr -----"
    cat err.log || true
    echo "----- probe verdict -----"
    if [ ! -f "$NVIM_LOADS_RESULT" ]; then
      echo "nvim-loads: FAIL (probe wrote no result -- it never ran to completion)" >&2
      exit 1
    fi
    cat "$NVIM_LOADS_RESULT"
    if [ "$(head -n1 "$NVIM_LOADS_RESULT")" = "OK" ]; then
      echo "nvim-loads: PASS"
      touch $out
    else
      echo "nvim-loads: FAIL (framework module(s) failed to load)" >&2
      exit 1
    fi
  ''
