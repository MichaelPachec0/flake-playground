{ pkgs }:
{
  # ── nixpkgs passthroughs ─────────────────────────────────────────────────────

  # cmakerc 2.0.1 — in nixpkgs
  cmakerc = pkgs.cmakerc;

  # miniaudio 0.11.25 — single-header library. The nixpkgs `miniaudio` package only
  # ships the compiled node .so files and does NOT install miniaudio.h. The client
  # uses miniaudio as a header-only library (soundmanager.cpp defines
  # MINIAUDIO_IMPLEMENTATION then #include <miniaudio.h>), so provide the header from
  # the same upstream source nixpkgs pins.
  miniaudio = pkgs.stdenv.mkDerivation {
    pname = "miniaudio";
    version = "0.11.25";
    src = pkgs.fetchFromGitHub {
      owner = "mackron";
      repo = "miniaudio";
      rev = "0.11.25";
      hash = "sha256-2k346Z/ueINPbaY20P2cbBvRfFXXH0ugdv4d7WaYt2w=";
    };
    phases = [ "unpackPhase" "installPhase" ];
    installPhase = ''
      mkdir -p $out/include
      cp miniaudio.h $out/include/
    '';
  };

  # ── vendored derivations ─────────────────────────────────────────────────────

  # skyr-url v1.13.0 (cpp-netlib/url) — NOT in nixpkgs
  # Transitive deps: tl-expected, range-v3, nlohmann_json (all in nixpkgs).
  skyr-url = pkgs.stdenv.mkDerivation {
    pname = "skyr-url";
    version = "1.13.0";
    src = pkgs.fetchFromGitHub {
      owner = "cpp-netlib";
      repo = "url";
      rev = "v1.13.0";
      hash = "sha256-f+WcXdvsIGfXUIIK039DP3GS/BzOMbx9lH0G2ZM9NOg=";
    };
    nativeBuildInputs = [ pkgs.cmake ];
    propagatedBuildInputs = [ pkgs.tl-expected pkgs.range-v3 pkgs.nlohmann_json ];
    cmakeFlags = [
      "-Dskyr_BUILD_TESTS=OFF"
      "-Dskyr_BUILD_DOCS=OFF"
      "-Dskyr_BUILD_EXAMPLES=OFF"
      "-Dskyr_WARNINGS_AS_ERRORS=OFF"
      "-Dskyr_ENABLE_FILESYSTEM_FUNCTIONS=OFF"
    ];
  };

  # cpp-base64 V2.rc.08 (ReneNyffenegger/cpp-base64) — NOT in nixpkgs
  # Installs base64.h + base64.cpp to $out/include/cpp-base64/.
  cpp-base64 = pkgs.stdenv.mkDerivation {
    pname = "cpp-base64";
    version = "2.rc.08";
    src = pkgs.fetchFromGitHub {
      owner = "ReneNyffenegger";
      repo = "cpp-base64";
      rev = "V2.rc.08";
      hash = "sha256-6O0nmrC4pnzN4R3TOLCd+8cyje/n8mpCXX4lDYlXnHE=";
    };
    phases = [ "unpackPhase" "installPhase" ];
    installPhase = ''
      mkdir -p $out/include/cpp-base64
      # cpp-base64 is compile-in-place; base64.cpp lives alongside header by design.
      cp base64.h base64.cpp $out/include/cpp-base64/
    '';
  };

  # advobfuscator 2020-06-26 (andrivet/ADVobfuscator) — NOT in nixpkgs
  # Header-only; installs Lib/ to $out/include/.
  advobfuscator = pkgs.stdenv.mkDerivation {
    pname = "advobfuscator";
    version = "unstable-2020-06-26";
    src = pkgs.fetchFromGitHub {
      owner = "andrivet";
      repo = "ADVobfuscator";
      rev = "1852a0eb75b03ab3139af7f938dfb617c292c600";
      hash = "sha256-qleFYWPmCYHHtBO3Op3e8T6fxmC/3KwpatcQ8keiiz8=";
    };
    phases = [ "unpackPhase" "installPhase" ];
    installPhase = ''
      mkdir -p $out/include
      cp -r Lib $out/include/
    '';
  };
}
