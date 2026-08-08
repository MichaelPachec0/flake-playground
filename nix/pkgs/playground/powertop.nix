# powertop, built from the latest upstream master commit. nixpkgs is pinned to
# the v2.15 release; master is ~600 commits past that tag (upstream's own
# meson.build calls it 2.16-rc3) and is where the libtracefs/libtraceevent-backed
# tracing lives -- upstream's README lists both as build dependencies, and
# meson.build hard-requires libtracefs, but the nixpkgs derivation provides
# neither.
#
# BUILT WITH MESON, NOT THE INHERITED AUTOTOOLS. nixpkgs builds v2.15 with
# autoreconfHook, and master still ships configure.ac/autogen.sh -- but that path
# is ABANDONED upstream and does not produce a working binary:
#
#   * configure.ac still requests C++11 (AX_CXX_COMPILE_STDCXX([11])) while the
#     code has moved to std::format, so every translation unit that uses it fails
#     to compile. meson.build sets cpp_std=c++20.
#   * Bumping that to [20] then fails at LINK time: src/Makefile.am's source list
#     is stale, missing seven .cpp files that exist on disk and are registered
#     only in meson.build (cpu/frequency.cpp, cpu/xe_gpu.cpp,
#     devices/device_manager.cpp, devices/xe-gpu.cpp, gpu-tab.cpp,
#     measurement/measurement_manager.cpp, report/report-formatter-md.cpp) --
#     hence undefined references to frequency::frequency(), xe_core::xe_core(),
#     global_power(), report_formatter_md::report_formatter_md(), and friends.
#
# Chasing that with per-file Makefile.am patches would break on every source file
# upstream adds. meson is the maintained path, so we swap nativeBuildInputs to it
# and keep inheriting the rest (buildInputs, the out/man output split, meta).
# meson installs the binary, install_man('doc/powertop.8') and bash completion,
# so the inherited two-output layout still holds.
#
# `source` is an nvfetcher entry from ./_sources, giving the fetched git tree
# (src), the tracked commit and its date.
{
  lib,
  powertop,
  gettext,
  libtraceevent,
  libtracefs,
  meson,
  ninja,
  pkg-config,
  xset,
  source,
}: let
  # The tracked commit, abbreviated. Read from src.rev rather than
  # source.version: for a src.git entry nvfetcher sets version to the raw commit
  # sha, so the two agree today, but src.rev stays correct if this entry is ever
  # switched to release tracking (where version becomes a tag like "2.16").
  # 7 chars matches git's traditional --short default.
  shortRev = builtins.substring 0 7 source.src.rev;
in
  powertop.overrideAttrs (old: {
    # Tracking master, so there's no upstream tag to follow; use the commit date
    # plus short rev. The base is upstream's own in-tree version (meson.build:
    # 2.16-rc3), not the last release, so this still sorts after the 2.15 that
    # nixpkgs ships. The date leads the rev so version comparison stays
    # chronological -- compareVersions splits on the dashes and reaches the date
    # components first, leaving the rev to disambiguate same-day bumps only.
    version = "2.16-rc3-unstable-${source.date}-${shortRev}";

    inherit (source) src;

    # Replaces the inherited autoreconfHook/autoconf-archive set -- see the meson
    # rationale in the header comment. gettext is needed at BUILD time here
    # (msgfmt for po/), which the nixpkgs derivation gets away with listing only
    # in buildInputs because autotools tolerated it.
    nativeBuildInputs = [meson ninja pkg-config gettext];

    # The two dependencies from upstream's README that nixpkgs does not already
    # cover; meson.build hard-requires libtracefs. No `or []` fallback: nixpkgs
    # powertop always sets buildInputs, and a fallback would silently paper over
    # a future restructure.
    buildInputs = old.buildInputs ++ [libtraceevent libtracefs];

    # Replaces the inherited postPatch wholesale -- it is written against the
    # v2.15 tree and two of its three substitutions no longer apply to master:
    #
    #   * hcitool: GONE. Bluetooth tuning no longer shells out at all, so the
    #     nixpkgs `--replace-fail "/usr/bin/hcitool"` on src/tuning/bluetooth.cpp
    #     matches nothing and hard-fails the build.
    #   * xset: upstream moved the call into a try_xset_dpms() helper that
    #     invokes a BARE `xset` off $PATH (src/calibrate/calibrate.cpp) and
    #     ignores failures. The old `/usr/bin/xset` pattern now only occurs in
    #     that helper's comment, so patching it would be a silent no-op while the
    #     real system() call went unpatched. Anchor to the call site instead --
    #     matching the bare token `xset` would also hit the identifier
    #     `try_xset_dpms`.
    #   * modprobe: still present, and now twice; substituteInPlace rewrites
    #     every occurrence, so --replace-fail (which only fails on zero matches)
    #     holds.
    postPatch = ''
      substituteInPlace src/main.cpp \
        --replace-fail "/sbin/modprobe" "modprobe"
      substituteInPlace src/calibrate/calibrate.cpp \
        --replace-fail "DISPLAY=:0 xset dpms" "DISPLAY=:0 ${lib.getExe xset} dpms"
    '';

    # Both nixpkgs passthru entries are wrong once overridden: tests.version
    # compares the UNoverridden powertop binary against our new version (a
    # guaranteed mismatch), and updateScript = nix-update-script is a bumper that
    # nvfetcher has taken over.
    passthru = {};

    meta =
      # changelog is built from finalAttrs.version, so it would resolve to
      # releases/tag/v2.16-rc3-unstable-<date>-<rev> -- a 404. A master pin has
      # no release tag to point at.
      builtins.removeAttrs old.meta ["changelog"]
      // {
        # REQUIRED FOR EVALUATION, not cosmetic. nixpkgs does
        # `inherit (finalAttrs.src.meta) homepage`, and overrideAttrs rebinds
        # finalAttrs.src to the nvfetcher source above. That src is a fetchgit,
        # and while it does carry a `meta` (every mkDerivation does), fetchgit
        # never sets `meta.homepage` -- only fetchFromGitHub does. So the inherit
        # fails on the missing attribute and the derivation does not evaluate,
        # which takes down the eval-only flake checks, not just this build.
        homepage = "https://github.com/fenrus75/powertop";
      };
  })
