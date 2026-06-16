# flake-playground

Personal Nix flake: packages, NixOS modules, and a home-manager module
(`programs.nvchad`).

## Branch strategy

| Branch          | `nixpkgs` input  | neovim | Purpose                              |
|-----------------|------------------|--------|--------------------------------------|
| `main`/`master` | `nixos-unstable` | 0.12+  | Latest nixpkgs. Default branch.      |
| `stable`        | `nixos-25.11`    | 0.11.x | Tracks the current stable release.   |

The **only** intended difference between the branches is the `nixpkgs.url` line
in `flake.nix` (and the resulting `flake.lock`). Do feature work on `main`, then
merge/cherry-pick into `stable`, keeping the pin as the sole divergence.

Bump either branch with `nix flake update nixpkgs` (it follows whichever channel
that branch's `flake.nix` points at).

### Why the split matters

neovim **0.12** (on `main`/unstable) integrates treesitter into core and removed
several Lua APIs; **0.11** (on `stable`/25.11) does not. The packaged NvChad set
is pinned to revisions that build and run on 0.12. See
[`nix/pkgs/nvchad/NOTES.md`](nix/pkgs/nvchad/NOTES.md) for the full 0.11 -> 0.12
story and migration guide.
