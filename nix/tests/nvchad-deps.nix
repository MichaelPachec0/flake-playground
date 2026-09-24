# Dependency-drift gate for the nvfetcher-tracked NvChad set: every plugin that
# the packaged core's lazy spec (lua/nvchad/plugins/init.lua) asks for must be
# present in the home-manager module's lazy.nvim local packdir. lazy.nvim looks
# a local plugin up by its spec name (`name = ...`, else the repo basename minus
# `.git`), and vimUtils.packDir links each plugin as `lib.getName drv`, so the
# check compares those two name sets. A core bump that adds a plugin we do not
# ship fails here, and the daily updater does not commit it.
#
# Eval-only on the module side: lazyPlugins and its dependency closure are only
# walked for names, nothing in it is built (withAllGrammars stays unbuilt).
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
  cfg = hm.config.programs.nvchad;
  set = pkgs.callPackage ../pkgs/nvchad {};
  specFiles = [
    "${set.nvchad}/lua/nvchad/plugins/init.lua"
  ];

  # Same closure vimUtils.packDir links into pack/lazyPlugins/start.
  closure = p: [p] ++ lib.concatMap closure (p.dependencies or []);
  shipped = lib.unique (map lib.getName (lib.concatMap closure cfg.lazyPlugins));
  shippedFile = pkgs.writeText "nvchad-shipped-plugins" (lib.concatLines shipped);

  # Walks the spec table (strings, spec tables, nested `dependencies`) and
  # prints the lazy.nvim name of each plugin. The spec file only defines
  # functions, so dofile() needs none of the plugins it names.
  specNames = pkgs.writeText "nvchad-spec-names.lua" ''
    local seen = {}
    local function name_of(spec)
      local src = type(spec) == "string" and spec or spec[1] or spec.url or spec.dir
      if type(spec) == "table" and spec.name then return spec.name end
      if not src then return nil end
      return (src:gsub("/+$", ""):match("[^/]+$"):gsub("%.git$", ""))
    end
    -- Mirrors lazy.nvim's Spec:add: a table with several positional entries,
    -- or only positional entries, is a list of specs; otherwise one spec.
    local function is_list(t)
      local i = 0
      for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
      end
      return true
    end
    local function walk(spec)
      if type(spec) == "string" then spec = { spec } end
      if type(spec) ~= "table" then return end
      if #spec > 1 or (is_list(spec) and type(spec[1]) ~= "string") then
        for _, s in ipairs(spec) do walk(s) end
        return
      end
      local n = name_of(spec)
      if n and not seen[n] then seen[n] = true; print(n) end
      local deps = spec.dependencies
      if type(deps) == "string" then deps = { deps } end
      if type(deps) == "table" then for _, d in ipairs(deps) do walk(d) end end
    end
    for _, f in ipairs(arg) do walk(dofile(f)) end
  '';
in
  pkgs.runCommand "nvchad-deps" {nativeBuildInputs = [pkgs.luajit];} ''
    luajit ${specNames} ${lib.escapeShellArgs specFiles} | sort -u > wanted
    sort -u ${shippedFile} > shipped
    echo "NvChad specs ask for: $(tr '\n' ' ' < wanted)"
    missing=$(comm -23 wanted shipped)
    if [ -n "$missing" ]; then
      echo "nvchad-deps: FAIL, NvChad core wants plugins the module does not ship:" >&2
      echo "$missing" | sed 's/^/  - /' >&2
      echo "Add them to programs.nvchad.lazyPlugins (or fix the name in the nvchad postPatch)." >&2
      exit 1
    fi
    echo "nvchad-deps: PASS"
    touch $out
  ''
