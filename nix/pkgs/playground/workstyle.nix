# workstyle, built from the latest upstream commit (the nixpkgs copy is pinned
# to a 2023 revision). `source` is an nvfetcher entry from ./_sources, giving
# the fetched git tree (src) and its commit date.
{
  lib,
  rustPlatform,
  source,
}:
rustPlatform.buildRustPackage {
  pname = "workstyle";
  # Tracking the default branch, so there's no upstream tag to follow; use the
  # commit date for a readable, monotonic version (last tagged release: 0.9.0).
  version = "0.9.0-unstable-${source.date}";

  inherit (source) src;

  # Resolve crates.io deps straight from upstream's Cargo.lock so a source bump
  # needs no cargoHash to be recomputed. Only the swayipc-rs git dependency
  # needs a pinned hash, and that only changes if upstream repoints that branch.
  cargoLock = {
    lockFile = "${source.src}/Cargo.lock";
    outputHashes = {
      "swayipc-3.0.1" = "sha256-Aq+TTXXv1rhNaaP35yKGnnbSUtPfFfNSWxlFDL6RkJQ=";
      "swayipc-types-1.3.0" = "sha256-Aq+TTXXv1rhNaaP35yKGnnbSUtPfFfNSWxlFDL6RkJQ=";
    };
  };

  doCheck = false; # upstream ships no tests

  meta = {
    description = "Sway/i3 workspaces with style";
    homepage = "https://github.com/pierrechevalier83/workstyle";
    license = lib.licenses.mit;
    mainProgram = "workstyle";
  };
}
