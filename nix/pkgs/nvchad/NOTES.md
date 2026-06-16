# NvChad packaging notes & neovim 0.11 -> 0.12 migration

Covers the NvChad set packaged in `default.nix` (`nvchad`, `nvchad-ui`,
`base46`, plus the nvzone `volt`, `minty`, `menu`) and what the move to neovim
0.12 means for it.

## What's pinned, and why

| plugin      | repo            | branch     | rev (short) | date       |
|-------------|-----------------|------------|-------------|------------|
| `nvchad`    | `NvChad/NvChad` | `v2.5`     | `d042cc9`   | 2026-04-13 |
| `nvchad-ui` | `NvChad/ui`     | `v3.0`     | `3e67e9d`   | 2026-05-10 |
| `base46`    | `NvChad/base46` | `v3.0`     | `884b990`   | 2026-01-16 |
| `volt`      | `nvzone/volt`   | `main`     | `620de13`   | 2025-09-13 |
| `minty`     | `nvzone/minty`  | `main`     | `aafc9e8`   | 2025-02-28 |
| `menu`      | `nvzone/menu`   | `main`     | `7a0a4a2`   | 2025-06-01 |

Key decisions:

- **Mixed set: core on v2.5, ui + base46 on v3.0.** `NvChad/NvChad` has no v3.0
  branch yet (it tops out at `v2.5`/`dev`, which are byte-identical), but the
  `ui` and `base46` repos have moved to `v3.0`, and v3.0 ui/base46 are
  backward-compatible with the v2.5 core - verified on neovim 0.12: the set
  builds, loads, and `list_themes` finds all 94 themes. nixpkgs-unstable itself
  tracks v3.0 for ui/base46.
- **The core was the only 0.12 break.** Older `nvchad` revs used APIs neovim
  0.12 removed (`vim.tbl_islist`, the legacy `nvim-treesitter.configs.setup`,
  ...). Core **v2.5 HEAD (2026-04-13)** dropped them - that is the 0.12 fix.
- **History note.** The previous ui pin (`adcc97d`, Jan 2025) was *not* a v2.5
  commit - `git branch --contains` puts it on `v3.0`/`dev` (89 behind the v3.0
  tip, 201 ahead of the v2.5 tip). It was an early v3.0-line commit all along;
  this migration just moves ui (and base46) to the current v3.0 tip.

## Patches

- **`nvchad` `postPatch`** - renames `"L3MON4D3/LuaSnip"` -> `"L3MON4D3/luasnip"`
  and names the `"nvchad/ui"` lazy spec `nvchad-ui` (nixpkgs plugin names).
- **`nvchad-ui`: no patch.** v3.0 resolves the base46 themes directory
  dynamically (`debug.getinfo` on the loaded `base46` module), so it finds our
  packDir copy with no path patch. (The old `ui.patch` / `substituteInPlace`
  that hardcoded lazy.nvim's `data` path is gone as of the v3.0 bump.)

## nvim-require-check skips

`buildVimPlugin` require-checks every Lua module at build time. One is excluded:
- `menus.neo-tree` (`menu`) - optional `neo-tree.nvim` integration we don't
  bundle.

(`nvchad-ui` needs no extra skip on v3.0: the base derivation's own
`nvimSkipModules` already covers its `nvconfig`-only modules.)

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

### Future: NvChad v3.0 core

`ui` and `base46` are already on v3.0; only the **core** remains on v2.5 (no
v3.0 core branch exists yet). When one ships, bump `nvchad` too: that is what
moves the set off `nvim-treesitter-legacy` onto the new `nvim-treesitter`
(escaping the nixpkgs 26.11 removal deadline) and onto the 0.12-native
treesitter setup.
