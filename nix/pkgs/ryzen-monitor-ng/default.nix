{
  lib,
  stdenv,
  fetchFromGitHub,
  unstableGitUpdater,
}
: let
  ryzen-smu = fetchFromGitHub {
    owner = "amkillam";
    repo = "ryzen_smu";
    rev = "9f9569f889935f7c7294cc32c1467e5a4081701a";
    hash = "sha256-i8T0+kUYsFMzYO3h6ffUXP1fgGOXymC4Ml2dArQLOdk=";
  };
in
  stdenv.mkDerivation {
    pname = "ryzen-monitor-ng";
    version = "2.0.5-unstable-2025-06-28";

    # Upstream has not updated ryzen_smu header version
    # This fork corrects ryzen_smu header version and
    # adds support for Matisse AMD CPUs.
    src = fetchFromGitHub {
      owner = "plasmin";
      repo = "ryzen_monitor_ng";
      rev = "8b7854791d78de731a45ce7d30dd17983228b7b1";
      hash = "sha256-xdYNtXCbNy3/y5OAHZEi9KgPtwr1LTtLWAZC5DDCfmE=";
      # Upstream repo contains pre-compiled binaries and object files
      # that are out of date.
      # These need to be removed before build stage.
    };

    patchPhase = ''
      runHook prePatch
      # Grab the lastet ryzen-smu lib code replace the current lib code
      cp -r ${ryzen-smu}/lib src/
      cd src
      # ryzen-smu changed enumerator's prefix, for now do a really
      # brittle search replace, until either i or someone else
      # sends a pr
      find . -type f -exec sed -i "s/\sTYPE_/ SMU_TYPE_/g" {} \;
      runHook postPatch
    '';

    makeFlags = ["PREFIX=${placeholder "out"}"];

    passthru.updateScript = unstableGitUpdater {};

    meta = with lib; {
      description = "Access Ryzen SMU information exposed by the ryzen_smu driver";
      homepage = "https://github.com/plasmin/ryzen_monitor_ng";
      changelog = "https://github.com/plasmin/ryzen_monitor_ng/blob/master/CHANGELOG.md";
      license = licenses.agpl3Only;
      platforms = ["x86_64-linux"];
      maintainers = with maintainers; [phdyellow];
      mainProgram = "ryzen_monitor";
    };
  }
