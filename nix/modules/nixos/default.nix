# Aggregate NixOS module: imports every NixOS module under nix/modules/nixos.
# Pull them all in with `imports = [ nixosModules.default ]`, then enable only
# the ones you want - each module's config is gated behind its own enable
# option, so importing them all is inert until enabled.
#
# cynthion/realsense/zsa/tuwunel are `inputs`-prefixed; hyprpolkitagent is a
# plain module taking no inputs.
inputs: {
  imports = [
    (import ./cynthion inputs)
    (import ./realsense inputs)
    (import ./zsa inputs)
    (import ./hyprpolkitagent)
    (import ./tuwunel inputs)
  ];
}
