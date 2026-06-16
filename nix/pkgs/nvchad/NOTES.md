# NvChad packaging notes & neovim 0.11 -> 0.12 migration

Covers the NvChad set packaged in `default.nix` (`nvchad`, `nvchad-ui`,
`base46`, plus the nvzone `volt`, `minty`, `menu`) and what the move to neovim
0.12 means for it.

## What's pinned, and why

| plugin      | repo            | branch     | rev (short) | date       |
|-------------|-----------------|------------|-------------|------------|
| `nvchad`    | `NvChad/NvChad` | `v2.5`     | `d042cc9`   | 2026-04-13 |
| `nvchad-ui` | `NvChad/ui`     | (off-tip)  | `adcc97d`   | 2025-01-15 |
| `base46`    | `NvChad/base46` | `v2.5`     | `fde7a2c`   | 2025-01-17 |
| `volt`      | `nvzone/volt`   | `main`     | `620de13`   | 2025-09-13 |
| `minty`     | `nvzone/minty`  | `main`     | `aafc9e8`   | 2025-02-28 |
| `menu`      | `nvzone/menu`   | `main`     | `7a0a4a2`   | 2025-06-01 |

Key decisions:

- **Stay on the NvChad v2.5 line.** There is no v3.0 *core* yet -
  `NvChad/NvChad` tops out at `v2.5`/`dev`, and `dev` is byte-identical to
  `v2.5`. The `ui`/`base46` `v3.0` branches are ahead of any released core, so
  bundling them would orphan them against a v2.5 core. Revisit when a v3.0 core
  ships (see bottom).
- **The core was the only 0.12 break.** Older `nvchad` revs used APIs neovim
  0.12 removed (`vim.tbl_islist`, the legacy `nvim-treesitter.configs.setup`,
  ...). Core **v2.5 HEAD (2026-04-13)** dropped them - that is the 0.12 fix. `ui`
  and `base46` were already 0.12-clean (they use `vim.uv`, etc.).
- **`nvchad-ui` stays at `adcc97d`.** It is *newer* than the current v2.5 branch
  tip (NvChad reset `v2.5` backward), and the tip (`e0f06a9`, 2024-09-30) fails
  `nvim-require-check`. `adcc97d` builds, is 0.12-clean, and pairs with the
  updated core.

## Patches

- **`nvchad` `postPatch`** - renames `"L3MON4D3/LuaSnip"` -> `"L3MON4D3/luasnip"`
  and names the `"nvchad/ui"` lazy spec `nvchad-ui` (nixpkgs plugin names).
- **`nvchad-ui` `postPatch`** (was `ui.patch`) - redirects base46 theme
  discovery from lazy.nvim's `stdpath "data" .. "/lazy/base46/..."` to our packDir
  path `stdpath "config" .. "/lazyPlugins/pack/lazyPlugins/start/base46/..."`.
  Converted from a context `.patch` to `substituteInPlace --replace-fail` so it
  survives surrounding-line churn and fails loudly if upstream moves the line.
  (NvChad `ui` **v3.0** computes this path dynamically and would need no patch.)

## nvim-require-check skips

`buildVimPlugin` require-checks every Lua module at build time. Two can't be:
- `menus.neo-tree` (`menu`) - optional `neo-tree.nvim` integration we don't
  bundle.
- `nvchad.tabufline.modules` (`nvchad-ui`) - `require("nvconfig")`, your runtime
  config, never present at build time. **Appended** to the base derivation's
  skip list (`(old.nvimSkipModules or []) ++ ...`), not replacing it - the base
  list already covers `term`, `themes`, `cheatsheet`, etc.

## neovim 0.11 -> 0.12 migration

Context: `main` tracks `nixos-unstable` (**neovim 0.12+**); `stable` tracks
`nixos-25.11` (**0.11.x**). So on `main` you are on 0.12 now.

1. **Treesitter is in core.** 0.12 ships the engine + bundled parsers *and*
   queries for **7** languages (`c lua vim vimdoc query markdown
   markdown_inline`) with highlighting on by default. It does **not** bundle
   other languages - provide those grammars via nix, and **use
   `nvim-treesitter-legacy`** (what NvChad v2.5 bundles), not the new
   `nvim-treesitter` (see point 2):

   ```nix
   programs.nvchad.extraLazyPlugins = [ pkgs.vimPlugins.nvim-treesitter-legacy.withAllGrammars ];
   # or a curated subset:
   #   builtins.attrValues (lib.getAttrs [ "nix" "python" "rust" ]
   #     pkgs.vimPlugins.nvim-treesitter-legacy.grammarPlugins)
   ```

   Mixing the new `nvim-treesitter` with NvChad's bundled
   `nvim-treesitter-legacy` trips `vimUtils.packDir`'s *"two different versions
   of nvim-treesitter"* guard. `:TSInstall` is a non-option - the config dir is
   a read-only nix store path.

2. **`nvim-treesitter` was archived (2026-04-03); nixpkgs split it.** The old
   master-branch plugin (with `configs.setup()`) is now
   **`nvim-treesitter-legacy`** - deprecated, and an *error* in nixpkgs 26.11 -
   while the main-branch rewrite took the `nvim-treesitter` name. NvChad v2.5
   depends on `nvim-treesitter-legacy`; its `configs.setup()` still works, but
   gets no parser updates and is on borrowed time (26.11).

3. **Avoid the core-vs-treesitter parser clash** for the 7 bundled langs. Pick
   one owner:
   - let **core** own them (exclude those 7 from your grammar set) - then you
     don't need the rtp-remove hack; or
   - let **nvim-treesitter** own them and remove core's parsers from rtp.

   Package/version-agnostic removal for your `nv` init (no nix interpolation -
   the path on rtp is the *unwrapped* neovim, not `programs.nvchad.package`):

   ```lua
   for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
     if p:match("/lib/nvim$") then vim.opt.rtp:remove(p) end
   end
   ```

4. **Grammars belong in the `start` packdir, not lazy-loaded.** lazy.nvim resets
   rtp, so deliver grammars through `extraLazyPlugins` (-> `pack/lazyPlugins/
   start`) rather than relying on an `rtp:append` hack.

5. **LSP / completion (optional, your `nv` config).** 0.12 has native
   `vim.lsp.config()` / `vim.lsp.enable()` and `vim.o.autocomplete`;
   `nvim-lspconfig` is deprecated. NvChad still wires its own - migrate at
   leisure.

6. **`vim.pack`** (native plugin manager) exists but we keep lazy.nvim via the
   packDir; no change needed.

### Future: NvChad v3.0

When a v3.0 **core** ships, the cleaner 0.12-native path opens: `ui` v3.0
already resolves the base46 path dynamically (drop the `nvchad-ui` postPatch),
and the set moves off `nvim-treesitter-legacy` onto the new `nvim-treesitter`,
escaping the nixpkgs 26.11 removal deadline. Bump all three NvChad repos to v3.0
**together** - never mix v3.0 `ui`/`base46` with a v2.5 core.
