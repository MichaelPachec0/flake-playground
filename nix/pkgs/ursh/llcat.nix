{ fetchFromGitHub, pyproject-nix, python3, ... }:
let
  llcat = pyproject-nix.lib.project.loadPyproject {
    projectRoot = fetchFromGitHub {
      owner = "day50-dev";
      repo = "llcat";
      rev = "refs/tags/v0.13.19";
      # rev = "da26c59ad3fa2ba59e279563c1d8426134dba795";
      hash = "sha256-gMf5HyDAWFaxBQcuSMUMHFPPMate5YMIDBexZUrivB0=";
    } ;

  };
  python = python3;
  attrs = llcat.renderers.buildPythonPackage { inherit python; };
in python.pkgs.buildPythonPackage (attrs)