{
  pkgs,
  sources,
}:
pkgs.buildGoModule {
  pname = "windscribe-wstunnel";
  version = pkgs.lib.removePrefix "v" sources.wstunnel.version;
  # Version is coupled to the Desktop-App tag (upstream pins it in
  # tools/vars/wstunnel.yml); tracked by nvfetcher in ../nvfetcher.toml.
  inherit (sources.wstunnel) src;
  # NOT tracked by nvfetcher: a wstunnel bump changes this hash, the build
  # fails with `got: sha256-...`, and a human pastes the new value here.
  vendorHash = "sha256-sl1QKXijUj/uM+3fOuufFQH0+X8I07UVTEOSPteNDYQ="; # go.mod has a local replace for gorilla/websocket; buildGoModule vendors it
  # build only the root package; ./websocket is a local-replace module, not a buildable subpackage
  subPackages = ["."];
  # match upstream build flags (strip debug info / symbol table)
  ldflags = ["-w" "-s"];
}
