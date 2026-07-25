# The `mcp.*` NixOS module family: one file per MCP server, each self-contained
# (options + package + systemd service, gated behind its own `enable`). Import
# the whole family with `imports = [ nixosModules.mcp ]` (or via
# nixosModules.default). Add a new server by dropping `<name>.nix` here and one
# import line below.
inputs: {
  imports = [
    (import ./affine.nix inputs)
  ];
}
