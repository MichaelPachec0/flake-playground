{
  stdenv,
  lib,
  fetchFromGitHub,
}:
stdenv.mkDerivation rec {
  name = "MemTimings-Linux";
  # NOTE: no version is specified
  version = "0.0.1-master";

  src = fetchFromGitHub {
    owner = "Connor-GH";
    repo = name;
    rev = "d0cb4d2ce6f8434c242e7bb0ccb78fa48482c53d";
    hash = "sha256-2zm89j4becgKgQCaeaE4xlXbVhhiE5BI/DGdGvbIS50=";
  };
  buildPhase = ''
    gcc -o timings timings.c
  '';
  installPhase = ''
    mkdir -p $out/bin
    chmod +x timingsaddon.sh
    cp timingsaddon.sh $out/bin
    cp timings $out/bin
  '';


  meta = {
    description = "Find your memory Timings of a Ryzen Zen2+ cpu under linux!";
    homepage = "https://github.com/Connor-GH/MemTimings-Linux";
    license = lib.licenses.gpl3Plus;
    mainProgram = "timingsaddon.sh";
    maintainers = with lib.maintainers; [];
  };
}
