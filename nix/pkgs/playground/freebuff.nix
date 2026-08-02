# freebuff, Codebuff's coding-agent CLI, packaged from the upstream prebuilt
# release tarball. `source` is the nvfetcher entry matching the build's host
# platform, picked in ./default.nix (version scraped off the npm registry, binary
# fetched from the CodebuffAI/codebuff-community GitHub release -- see
# ./nvfetcher.toml for why it is split that way).
#
# `source.pname` is the per-target entry name (freebuff-linux-arm64, ...), so
# pname is set explicitly here: the derivation is the same program on every
# platform and should not carry the target in its name.
#
# The tarball is flat: a single Bun-compiled binary (~50-125MB depending on
# target) plus the tree-sitter WASM blob it loads at runtime. Upstream's npm
# launcher normally drops the two side by side in ~/.config/freebuff and execs
# the binary from there; we keep that adjacency in $out/libexec and expose
# $out/bin/freebuff as a wrapper, so the binary still resolves tree-sitter.wasm
# next to its own executable path.
#
# NOTE: `dontStrip`. Bun appends the JS bundle + its metadata to the executable
# as trailing data; stripping can drop it and leave a binary that dies on
# startup. On Darwin it would also break the code signature upstream ships.
{
  lib,
  stdenv,
  autoPatchelfHook,
  makeWrapper,
  source,
}:
stdenv.mkDerivation {
  pname = "freebuff";
  inherit (source) version src;

  # Flat tarball (./freebuff, ./tree-sitter.wasm) -- no component to strip.
  sourceRoot = ".";

  # ELF-only: the Darwin builds are Mach-O and need no interpreter rewrite. The
  # Linux binaries link nothing but glibc (verified with `auto-patchelf: 0
  # dependencies could not be satisfied`), so libgcc is the whole buildInputs.
  nativeBuildInputs =
    [makeWrapper]
    ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];

  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 freebuff -t $out/libexec/freebuff
    install -Dm444 tree-sitter.wasm -t $out/libexec/freebuff
    makeWrapper $out/libexec/freebuff/freebuff $out/bin/freebuff

    runHook postInstall
  '';

  meta = {
    description = "Codebuff's free coding-agent CLI";
    homepage = "https://freebuff.com";
    downloadPage = "https://github.com/CodebuffAI/codebuff-community/releases";
    mainProgram = "freebuff";
    # Upstream ships prebuilt binaries only; the sources are private
    # (github.com/CodebuffAI/freebuff-private).
    license = lib.licenses.unfree;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    # Keep in sync with the tracked freebuff-* entries in ./nvfetcher.toml and
    # the platform table in ./default.nix. Upstream also builds darwin-x64,
    # win32-x64 and the non-AVX2 `-baseline` variants.
    platforms = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
  };
}
