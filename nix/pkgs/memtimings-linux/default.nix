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
  # x86 variable shift takes its count in %cl, not %ecx; newer binutils (gas, on
  # nixos-unstable) rejects `shll %ecx, %edx`. Upstream bug - the value is
  # unaffected (%cl is %ecx's low byte and the count here is 0-31).
  postPatch = ''
    substituteInPlace timings.c \
      --replace-fail '%%ecx, %%edx' '%%cl, %%edx'
  '';
  buildPhase = ''
    runHook preBuild
    gcc -o timings timings.c
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    chmod +x timingsaddon.sh
    cp timingsaddon.sh $out/bin
    cp timings $out/bin
    runHook postInstall
  '';


  meta = {
    description = "Find your memory Timings of a Ryzen Zen2+ cpu under linux!";
    homepage = "https://github.com/Connor-GH/MemTimings-Linux";
    license = lib.licenses.gpl3Plus;
    mainProgram = "timingsaddon.sh";
    maintainers = with lib.maintainers; [];
  };
}
