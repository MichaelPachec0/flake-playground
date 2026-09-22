# arduino-flasher-cli plus the qdl revision it embeds. Source is pinned to an
# upstream release tag rather than tracked by nvfetcher: flashing firmware is
# not something to silently roll forward on a daily bump.
{pkgs}: let
  qdl-arduino = pkgs.callPackage ./qdl.nix {};
in {
  inherit qdl-arduino;
  arduino-flasher-cli = pkgs.callPackage ./arduino-flasher-cli.nix {qdl = qdl-arduino;};
}
