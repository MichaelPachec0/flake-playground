# flake-playground

A personal Nix flake that packages software missing from (or newer than) nixpkgs,
together with the NixOS modules, home-manager modules, overlays, and custom
neovim plugins used by the author's `nix-config`. It is a staging area: things
are built and exercised here, then consumed elsewhere by adding this flake as an
input and `follows`-ing nixpkgs.

Everything targets `x86_64-linux` and is built with `allowUnfree = true`.

## Branch strategy

| Branch          | `nixpkgs` input  | neovim |
|-----------------|------------------|--------|
| `main`/`master` | `nixos-unstable` | 0.12+  |
| `stable`        | `nixos-25.11`    | 0.11.x |

The only intended difference between the branches is the `nixpkgs.url` line in
`flake.nix` (and the resulting `flake.lock`). Develop on `main`, then merge into
`stable`, keeping the pin as the sole divergence.

The split matters because neovim 0.12 moved treesitter into core and removed Lua
APIs that 0.11 still provides. The packaged NvChad set is pinned to revisions
that build and run on 0.12; see `nix/pkgs/nvchad/NOTES.md` for the full 0.11 ->
0.12 story and the pinning rationale.

## Inputs

- `nixpkgs` - `nixos-unstable` on `main`, `nixos-25.11` on `stable`.
- `flake-utils`.
- `pyproject-nix` - builds the Python projects below straight from their
  `pyproject.toml`; `follows` nixpkgs.
- `cspell-dicts` (`flake = false`) - dictionary source tree consumed by the
  cspell home-manager module.

## Outputs

### `packages.x86_64-linux`

Build any with `nix build .#<attr>`.

| Attr | Description |
|------|-------------|
| `linux-show-player` | FrancescoCeruti/linux-show-player 0.6.5, a Qt5/GStreamer cue player for stage productions. Built from source as a `buildPythonApplication`; the runtime Python deps not in nixpkgs are packaged inline (JACK-Client pinned to the absolute `libjack` path, pyalsa, the FrancescoCeruti `pyliblo3` fork that keeps the `liblo` module name, and qdigitalmeter). |
| `cynthion` | Great Scott Gadgets Cynthion 0.1.8, a USB analysis/development tool. `buildPythonApplication` that bundles the amaranth / luna-usb / luna-soc / apollo-fpga / usb-protocol deps at specific versions. On unstable it relaxes the `pygreat` bound (cynthion pins `~=2024.0`; unstable ships 2026.x). |
| `memtimings-linux` | Connor-GH/MemTimings-Linux, a small C program that reads DDR memory timings on Ryzen Zen2+ CPUs. Patched so its inline-asm `shll %ecx, %edx` uses `%cl` (newer binutils rejects the register form). |
| `ryzen-monitor-ng` | plasmin/ryzen_monitor_ng (fork), reads Ryzen SMU telemetry exposed by the `ryzen_smu` kernel driver. Vendors a forked `ryzen_smu` lib (adds Matisse support) and search-replaces a renamed enum prefix. |
| `ursh` | day50-dev/ursh, a Go CLI (the `/cli` subtree; `buildGoModule`). |
| `urchin` | The Python component of day50-dev/ursh (the `/urchin` subtree), built from `pyproject.toml` via pyproject-nix. |
| `llcat` | day50-dev/llcat v0.13.19, a Python package built via pyproject-nix. |
| `nvchad`, `nvchad-ui`, `base46`, `minty`, `volt`, `menu` | The NvChad neovim plugin set: core on the `v2.5` branch, `ui`/`base46` on `v3.0`, plus the nvzone plugins (`volt`, `minty`, `menu`). Revs are hand-pinned. The `nvchad` package replaces NvChad's `nvim-treesitter-legacy` dependency with the new `nvim-treesitter` (which core `d042cc9` requires) and carries small nixpkgs-name patches. See `nix/pkgs/nvchad/NOTES.md`. |

`affine-server` isn't in the table above (it's sourced from the `playground`
set, see below) but is exposed directly at `packages.x86_64-linux.affine-server`
for `nix build .#affine-server`. It patches a ~1-2 GB upstream OCI image, so -
like `windscribe` - it's deliberately kept out of the `packages`/`default` CI
check aggregates while staying buildable on demand; `nixosModules.affine`
uses it as `services.affine.package`'s default.

### `legacyPackages.x86_64-linux.vimPlugins`

A nested set of roughly thirty neovim plugins migrated from `nix-config` that are
not in nixpkgs (or are tracked at a newer commit). Sources are tracked by
nvfetcher (`nix/pkgs/vimPlugins/nvfetcher.toml` -> `_sources/`), each following
the latest commit on its upstream default branch. Only the per-plugin build
metadata - dependencies, skipped require-check modules, patches, build phases -
lives in `nix/pkgs/vimPlugins/default.nix`. Attribute names match `nix-config`'s
old overlay, so the `vimPlugins` overlay below is a drop-in replacement.

One exception: `nvim-treesitter-context` is *not* nvfetcher-tracked. It is
nixpkgs' plugin re-exported with a local patch
(`nix/pkgs/vimPlugins/patches/treesitter-context-include-visible.patch`, adding
an `include_visible` option), so it follows the flake's nixpkgs pin instead of
upstream HEAD - a context-sensitive patch would otherwise break on an arbitrary
daily source bump. The attribute deliberately shadows the nixpkgs one, so
configs using the stock name get the patched build.

Build one with `nix build .#legacyPackages.x86_64-linux.vimPlugins.<name>`.

### `legacyPackages.x86_64-linux.playground`

A nested set of third-party packages we want at their latest upstream commit
rather than the (often stale) nixpkgs revision. Same nvfetcher arrangement as
`vimPlugins`: sources are tracked in `nix/pkgs/playground/nvfetcher.toml` ->
`_sources/`, and per-package build metadata lives next to
`nix/pkgs/playground/default.nix`.

- `workstyle` - pierrechevalier83/workstyle, "workspaces with style" for sway/i3
  (nixpkgs pins a 2023 revision; this tracks the default branch). Built with
  `buildRustPackage`; crates.io deps resolve from upstream's `Cargo.lock`
  (`cargoLock.lockFile`) so a source bump needs no `cargoHash`, and only the
  `swayipc-rs` git dependency carries a pinned `outputHashes` entry.
- `affine-server` - the self-hosted AFFiNE server (`toeverything/affine` ghcr
  image, nvfetcher-pinned by digest). Built Path B: the OCI image is unpacked
  and `autoPatchelf`-ed into a native `node dist/main.js` bundle, no container
  runtime required. Pulls a ~1-2 GB image at build time, so it's excluded from
  the `playground`/`default` CI checks; build on demand with
  `nix build .#affine-server`. Backs the `services.affine` NixOS module below.
- `freebuff` - Codebuff's coding-agent CLI, from the upstream prebuilt release
  tarballs. Upstream ships an `npx freebuff` launcher that self-downloads the
  real binary at runtime; that pins nothing, so the launcher is skipped and the
  binary it would fetch is pinned instead. nvfetcher 0.8.0 has no npm version
  source, so the version is scraped off `registry.npmjs.org/freebuff/latest`
  (`src.webpage`) while the binary comes from the
  `CodebuffAI/codebuff-community` GitHub release (`fetch.url`). Releases are
  per-target tarballs, so there is **one nvfetcher entry per platform**
  (`freebuff-linux-x64`, `freebuff-linux-arm64`, `freebuff-darwin-arm64`) and
  `default.nix` picks the one matching `stdenv.hostPlatform`; an untracked
  platform fails with a pointed error rather than silently building the wrong
  arch. Also exposed as `packages.{x86_64-linux,aarch64-linux}.freebuff`.
  Upstream's `darwin-x64` and non-AVX2 `-baseline` assets are not tracked - see
  the comment in `nvfetcher.toml` for adding them.

Build one with `nix build .#legacyPackages.x86_64-linux.playground.<name>`.

### `checks.x86_64-linux`

- `packages` - a `linkFarm` of every first-class package in
  `packages.x86_64-linux`. A package that fails to build fails the check.
- `vimplugins` - a `linkFarm` of every custom plugin. Each plugin runs
  `buildVimPlugin`'s `nvim-require-check` at build time, so a plugin whose Lua
  modules no longer load fails the build.
- `playground` - a `linkFarm` of every `playground` package, so a source bump
  that no longer builds fails the build.
- `nvim-loads` - boots a headless neovim with the whole set on the packpath (the
  NvChad plugins, a representative slice of the runtime plugins the nvchad module
  ships, and every custom plugin) and `pcall(require)`s the framework modules.
  This catches breakage that only appears when the set is loaded together:
  startup-script errors, removed APIs after a source bump, version conflicts.
- `nixos-cynthion`, `nixos-realsense`, `nixos-zsa`, `nixos-hyprpolkitagent`,
  `nixos-tuwunel`, `nixos-affine` - *evaluate* the resulting NixOS system with
  each module enabled. These catch option-name typos, missing references, and
  structural breakage without building the full system closure. `affine`'s
  package build is heavy (see `packages.x86_64-linux` above), so this check
  only evaluates the module - it does not build `affine-server`.
- `hm-nvchad`, `hm-cspell` - the same, for the home-manager modules.
- `default` - all of the above. CI builds this.

### `overlays`

- `playground` (also `default`) - exposes the packages under `pkgs.playground.*`:
  `linux-show-player`, `cynthion`, `ryzen-monitor-ng`, `ursh`, `urchin`, `llcat`,
  `nvchad` (the full set, i.e.
  `pkgs.playground.nvchad.{nvchad,nvchad-ui,base46,minty,volt,menu,all}`), and the
  nvfetcher-tracked latest-upstream packages (`workstyle`).
- `vimPlugins` - merges the custom plugins into `pkgs.vimPlugins`, so
  `pkgs.vimPlugins.<name>` resolves for consumers. This is the drop-in for
  `nix-config`'s old `local` overlay.

### `nixosModules`

| Module | Option(s) | Effect |
|--------|-----------|--------|
| `cynthion` | `hardware.cynthion.enable` | Installs `uaccess` udev rules for Cynthion/Apollo USB hardware and the `cynthion` CLI built with `nixosInstall = true`. |
| `realsense` | `hardware.realsense.{enable,gui.enable,cli.enable}` | udev rules for Intel RealSense cameras, plus `librealsense` (gui or cli build). |
| `zsa` | `hardware.zsa.{wally,oryx,legacy}.enable` | udev rules for ZSA keyboards (Moonlander, Ergodox EZ, Planck EZ). |
| `hyprpolkitagent` | `services.hyprpolkitagent.enable` | systemd user service running the hypr polkit agent. |
| `tuwunel` | `services.tuwunel.enable` | systemd service for the tuwunel Matrix server (`pkgs.matrix-tuwunel`). `registration_token_file` is loaded as a systemd credential and the generated config points at it. |
| `affine` | `services.affine.enable` | Runs a self-hosted AFFiNE server (`pkgs.playground.affine-server`) natively under hardened systemd units - no container runtime. Provisions PostgreSQL (+pgvector) and Redis, loads sops-nix secrets via `LoadCredential`, serves local-FS (or best-effort S3) blob storage, and can front itself with an optional nginx+ACME reverse proxy. |

`default` imports every module above (from `nix/modules/nixos/default.nix`);
enable only the ones you want, since each module's config is gated behind its own
enable option.

**`affine` prerequisites & first admin.** `x86_64-linux` only; ~4 vCPU / 2 GB
RAM at runtime. Building `affine-server` needs network egress to `ghcr.io` and
~1-2 GB of scratch/disk to unpack the pinned OCI image. PostgreSQL and Redis
are provided by the module itself - no separate install unless you bring your
own. sops-nix (or agenix) is only needed for a remote/BYO database, S3
storage, or seeding the first admin account; a domain with ports 80/443 open
is only needed for the optional nginx+ACME path
(`services.affine.nginx.enable`). Minimal usage:

```nix
services.affine = {
  enable = true;
  externalUrl = "https://affine.example.com";
};
```

Seed the first admin with `services.affine.admin.email` +
`admin.passwordFile` (sops), or leave both unset and create the account at
`<externalUrl>/admin` after first boot. Post-v1 (not yet built): the
pgvector-backed AI/full-text indexer, S3 storage promoted out of best-effort,
a from-source (Path A) build behind the same package contract, a `nixosTest`
VM integration test, and ARM64.

### `homeManagerModules`

- `nvchad` - `programs.nvchad`. Installs neovim through
  `programs.neovim` and materializes the NvChad plugin set into a lazy.nvim local
  packdir at `~/.config/nvim/lazyPlugins`. Options:
  - `enable`
  - `package` - the (unwrapped) neovim to install
  - `lazyPlugins` - the default plugin list (the NvChad set plus the runtime
    plugins it needs); normally left untouched
  - `extraEarlyPlugins` - extra non-lazy plugins (loaded at startup)
  - `extraLazyPlugins` - extra plugins added to the lazy.nvim local search path
  - `extraEarlyConfig` / `extraConfig` - Lua placed early / later in the
    generated `init.lua`; put your NvChad starter's init bootstrap in
    `extraConfig` and your `lua/` modules at `~/.config/nvim/lua` via
    `xdg.configFile`.
- `cspell` - `programs.cspell`. Writes `~/.config/cspell/cspell.json`, importing
  the dictionary packs from the `cspell-dicts` input.

`default` imports both modules above (from
`nix/modules/home-manager/default.nix`).

### `devShells.x86_64-linux`

- `default` - `nvfetcher`, for regenerating the `nix/pkgs/{vimPlugins,playground}/_sources`.
- `cynthion`, `linux-show-player`, `memtimings-linux`, `ryzen-monitor-ng` -
  per-package shells (`ryzen-monitor-ng` uses `inputsFrom` for phase-by-phase
  debugging).

## Custom vim plugins and the update pipeline

The custom vim plugin sources are decoupled from their build definitions:

- nvfetcher tracks each plugin's latest upstream commit into
  `nix/pkgs/vimPlugins/_sources/generated.{json,nix}`.
- Regenerate locally:

  ```sh
  nix develop -c nvfetcher \
    -c nix/pkgs/vimPlugins/nvfetcher.toml \
    -o nix/pkgs/vimPlugins/_sources
  ```

All bump workflows gate their commit on `checks.x86_64-linux.default` (the
comprehensive CI gate, see [CI](#ci) below):

- `.github/workflows/update.yml` - daily (and on `nvfetcher.toml` changes),
  re-runs nvfetcher, builds the checks, and commits the regenerated `_sources`
  only if they pass.
- `.github/workflows/update-playground.yml` - the same, for the `playground` set
  (`nix/pkgs/playground/nvfetcher.toml`); gates its commit on the full
  `checks.x86_64-linux.default`.
- `.github/workflows/update-flake-lock.yml` - weekly, runs `nix flake update`,
  builds the checks, and commits `flake.lock` only if it passes.

The NvChad set (`nix/pkgs/nvchad`) is deliberately not nvfetcher-tracked: its
revs are hand-pinned for the v2.5-core / v3.0-ui compatibility documented in
`nix/pkgs/nvchad/NOTES.md`.

## CI

All CI runs a single gate over `checks.x86_64-linux`:

- **What it covers:** every first-class package (`packages` check), every custom
  vim plugin + the headless-nvim load test, the playground packages, and an
  *evaluation* of every NixOS and home-manager module (`nixos-*` / `hm-*` checks;
  each enables the module and evaluates the resulting system without building
  its full closure).
- **Run it locally:** `nix build .#checks.x86_64-linux.default`  
  or `nix run nixpkgs#nix-fast-build -- --flake .#checks.x86_64-linux --impure`.
- **When it runs:** on PRs and pushes to `main`/`master` (`ci.yml`), manually
  (workflow_dispatch), and inside the nightly/weekly bump workflows, which only
  commit a bump if the full check passes.

Not yet enforced (planned): warnings-as-errors and VM boot tests.

## Repository layout

```
flake.nix                      inputs and all outputs
nix/pkgs/                      package definitions (callPackage style)
  linux-show-player.nix
  cynthion/  memtimings-linux/  ryzen-monitor-ng/
  ursh/                        ursh (Go), urchin + llcat (Python via pyproject-nix)
  nvchad/                      NvChad plugin set + NOTES.md (0.11 -> 0.12 notes)
  vimPlugins/                  custom plugins: nvfetcher.toml, _sources/, default.nix
  playground/                  latest-upstream pkgs (workstyle): nvfetcher.toml, _sources/, default.nix
nix/modules/
  nixos/                       cynthion, realsense, zsa, hyprpolkitagent, tuwunel, affine
                               (+ default.nix importing all)
  home-manager/                nvchad, cspell; default.nix imports both
nix/tests/nvim-loads.nix      headless-nvim integration smoke test
.github/workflows/            CI: ci.yml, update.yml, update-playground.yml, update-flake-lock.yml
.github/actions/nix-checks/   composite action: runs nix-fast-build over checks
```

## Consuming this flake

```nix
# flake.nix of a consumer
{
  inputs.flake-playground.url = "github:MichaelPachec0/flake-playground";
  # inputs.flake-playground.inputs.nixpkgs.follows = "nixpkgs";
}
```

```nix
# build a package directly
# nix build github:MichaelPachec0/flake-playground#cynthion

# NixOS: an overlay + a hardware module
{ inputs, ... }:
{
  nixpkgs.overlays = [ inputs.flake-playground.overlays.default ];  # pkgs.playground.*
  imports = [ inputs.flake-playground.nixosModules.cynthion ];
  hardware.cynthion.enable = true;
}

# home-manager: the NvChad module
{ inputs, ... }:
{
  imports = [ inputs.flake-playground.homeManagerModules.nvchad ];
  programs.nvchad.enable = true;
}
```

## Constraints and known gaps

- `x86_64-linux` only; the system is hardcoded in `flake.nix`.
- `allowUnfree = true` is set inside the flake.

## License

MIT. See `LICENSE`.
