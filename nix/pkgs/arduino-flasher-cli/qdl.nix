# qdl pinned to linux-msm/qdl v2.4: the exact upstream revision that
# arduino-flasher-cli embeds. The tool ships a static qdl built by
# arduino/qdl-packing at tag v2.4-26, which is plain linux-msm/qdl v2.4 (run #26
# of their release pipeline) plus one patch that appends `--static` to LDFLAGS.
# That patch exists only to make a portable CI tarball; inside a store path the
# dynamic build is equivalent, so it is not applied here.
#
# Deliberately NOT nixpkgs' qdl (2.7.1): flasher-cli drives qdl with a fixed
# argv (--allow-missing, --storage emmc, positional firehose/rawprogram/patch
# XML) and screen-scrapes its log lines ("Waiting for", "Flashed"). Pinning the
# version upstream tests against keeps a qdl behavior change from turning into a
# bricked board.
#
# v2.4 predates qdl's move to meson, so this builds the plain Makefile and needs
# only libxml2 + libusb1 (2.7's libzip dependency does not exist yet here).
{
  lib,
  stdenv,
  fetchFromGitHub,
  pkg-config,
  libxml2,
  libusb1,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "qdl";
  version = "2.4";

  src = fetchFromGitHub {
    owner = "linux-msm";
    repo = "qdl";
    tag = "v${finalAttrs.version}";
    hash = "sha256-8jkuSNK7xTBUkBWzh766zKOlh+7pTr+e0xT1w3xifsw=";
  };

  strictDeps = true;

  nativeBuildInputs = [pkg-config];
  buildInputs = [libxml2 libusb1];

  # The Makefile derives VERSION from `git describe`, which has no .git to read
  # from here and would bake in "unknown-version".
  makeFlags = [
    "prefix=${placeholder "out"}"
    "VERSION=v${finalAttrs.version}"
    "CC=${stdenv.cc.targetPrefix}cc"
  ];

  enableParallelBuilding = true;

  meta = {
    homepage = "https://github.com/linux-msm/qdl";
    description = "Tool for flashing images to Qualcomm devices (pinned to the revision arduino-flasher-cli embeds)";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
    mainProgram = "qdl";
  };
})
