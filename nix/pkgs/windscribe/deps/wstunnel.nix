{ pkgs }:
pkgs.buildGoModule {
  pname = "windscribe-wstunnel";
  version = "1.0.6";
  src = pkgs.fetchFromGitHub {
    owner = "Windscribe"; repo = "wstunnel"; rev = "v1.0.6";
    hash = "sha256-WGLgZStXzZjseMumxQ2D1UFSdE3xZpYE6g5omPw6swQ=";
  };
  vendorHash = "sha256-Ma9bTnJmQ983Oio1c8T4eC4Sg45y0vGoaRIeKaSVhLM=";   # go.mod has a local replace for gorilla/websocket; buildGoModule vendors it
  # build only the root package — ./websocket is a local-replace module, not a buildable subpackage
  subPackages = [ "." ];
  # match upstream build flags (strip debug info / symbol table)
  ldflags = [ "-w" "-s" ];
}
