# arduino-flasher-cli: Arduino's tool for downloading and flashing Debian images
# onto UNO Q boards over Qualcomm EDL.
#
# Upstream's build has one non-Nix step. `task build` first runs
# internal/updater/artifacts/download_resources.sh, which `gh release download`s
# a prebuilt static qdl from arduino/qdl-packing into
# internal/updater/artifacts/resources_<goos>_<goarch>/, where a //go:embed
# directive picks it up. preBuild below replaces that download with the qdl
# derivation next to this file.
#
# The embed is kept rather than patched out. internal/updater/flasher.go
# extracts the embedded qdl to a temp dir at run time and then writes read.xml
# *next to it* (qdlPath.Parent().Join("read.xml")), so pointing qdlPath straight
# at ${qdl}/bin/qdl would make it try to write into the read-only store.
#
# The generated protobuf code (rpc/**/*.pb.go) is committed upstream, so there
# is no buf/protoc codegen step here.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  qdl,
}:
buildGoModule (finalAttrs: {
  pname = "arduino-flasher-cli";
  version = "0.5.3";

  src = fetchFromGitHub {
    owner = "arduino";
    repo = "arduino-flasher-cli";
    tag = "v${finalAttrs.version}";
    hash = "sha256-GImbuxAF+3i+ZHwH+h0rmo/BJ0CBN5eAuMbOVPKVtEg=";
  };

  vendorHash = "sha256-+Ag1OYgRFxLk16m8SlgiYT4eLzu1Nk5KRDQX3TUpQ5M=";

  # Path is derived from the Go target rather than hardcoded so this keeps
  # working when the package is built for another platform: upstream carries an
  # artifacts_<goos>_<goarch>.go with a matching embed for each one.
  preBuild = ''
    install -Dm755 ${lib.getExe qdl} \
      "internal/updater/artifacts/resources_$(go env GOOS)_$(go env GOARCH)/qdl"
  '';

  # main.Version is otherwise the literal "0.0.0-git", and the Taskfile encodes
  # untagged builds the same way.
  ldflags = [
    "-s"
    "-w"
    "-X"
    "main.Version=${finalAttrs.version}"
  ];

  meta = {
    homepage = "https://github.com/arduino/arduino-flasher-cli";
    description = "Download and flash Debian images onto Arduino UNO Q boards";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "arduino-flasher-cli";
  };
})
