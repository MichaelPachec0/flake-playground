# Aggregate home-manager module: imports every home-manager module under
# nix/modules/home-manager. Pull them all in with
# `imports = [ homeManagerModules.default ]`, then enable only the ones you want
# (programs.nvchad.enable, programs.cspell.enable). Each module's config is gated
# behind its own enable option.
#
# nvchad is a plain module (takes no inputs); cspell is `inputs`-prefixed (it
# reads the cspell-dicts input for its dictionary packs).
inputs: {
  imports = [
    (import ./nvchad)
    (import ./cspell inputs)
  ];
}
