# Aggregate NixOS module: imports every NixOS module in this directory, so a
# consumer can pull them all in with `imports = [ nixosModules.default ]` and
# then enable only the ones they want (each module's config is gated behind its
# own enable option, so importing them all is inert until enabled).
#
# Two import signatures are in play: cynthion/realsense/zsa are `inputs`-prefixed
# (they reference inputs.self for the packaged tools), while hyprpolkitagent is a
# plain module that takes no inputs.
inputs: {
  imports = [
    (import ./cynthion inputs)
    (import ./realsense inputs)
    (import ./zsa inputs)
    (import ./hyprpolkitagent)
  ];
}
