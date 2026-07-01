{ pkgs }:
pkgs.fetchFromGitHub {
  owner = "Windscribe";
  repo = "wsnet";
  rev = "1.5.20";
  hash = "sha256-2PGaoE0p3kr50rdVtvUnG5qdYERBuF5LF88qboxLZgc=";
}
