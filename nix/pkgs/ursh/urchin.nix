{ fetchFromGitHub, pyproject-nix, python3, ... }:
let
  urchin = pyproject-nix.lib.project.loadPyproject {
    projectRoot = fetchFromGitHub {
      owner = "day50-dev";
      repo = "ursh";
      rev = "fa9d1a4edc526e4174cb7e5a5850058185090e1a";
      hash = "sha256-Zqsv4CVtjJIwnNkfc/+/2abB8MtCXaS202Gwf8iyJWE=";
    } + "/urchin";

  };
  python = python3;
  attrs = urchin.renderers.buildPythonPackage { inherit python; };
in python.pkgs.buildPythonPackage (attrs)
