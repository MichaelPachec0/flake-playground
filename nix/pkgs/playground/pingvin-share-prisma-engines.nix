# Prisma engines matched to pingvin-share's @prisma/client 6.6.0.
# nixpkgs ships prisma-engines 7.10; Prisma rejects a client/engine version
# mismatch. Fetch the pinned 6.6.0 engine binaries by commit hash, then
# autoPatchelf them for NixOS. URL target + .gz sha256 differ per arch:
# x86_64 = debian-openssl-3.0.x, aarch64 = linux-arm64-openssl-3.0.x.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  openssl,
  zlib,
}: let
  engineHash = "f676762280b54cd07c770017ed3711ddde35f37a";
  base = "https://binaries.prisma.sh/all_commits/${engineHash}";

  # Target dir + per-file sha256 (of the .gz), keyed by nix system. Real
  # content hashes of the prebuilt engine files from binaries.prisma.sh.
  perSystem = {
    "x86_64-linux" = {
      target = "debian-openssl-3.0.x";
      queryHash = "sha256-PeZ1cfNzzlVGy8y6mqpeXWj7KCPQmaW+5EzsVcX+XG0=";
      schemaHash = "sha256-58Dw7bZGxQ9jeWU6yeBl+BZQagke1079cIAHvYL01Cg=";
    };
    "aarch64-linux" = {
      target = "linux-arm64-openssl-3.0.x";
      queryHash = "sha256-q4xDv7ty1MKOIq6+yZCQwq/lc1oBbxlBHJbw64Luz+g=";
      schemaHash = "sha256-zrDLE2Bdq6F6yIb9w1PeHNK5sx6JMHz6Ui3cJyJjR98=";
    };
  };
  sysCfg =
    perSystem.${stdenv.hostPlatform.system}
    or (throw "pingvin-share-prisma-engines: unsupported system ${stdenv.hostPlatform.system}");

  queryGz = fetchurl {
    url = "${base}/${sysCfg.target}/libquery_engine.so.node.gz";
    hash = sysCfg.queryHash;
  };
  schemaGz = fetchurl {
    url = "${base}/${sysCfg.target}/schema-engine.gz";
    hash = sysCfg.schemaHash;
  };
in
  stdenv.mkDerivation {
    pname = "pingvin-share-prisma-engines";
    version = "6.6.0";
    dontUnpack = true;

    nativeBuildInputs = [autoPatchelfHook];
    # DT_NEEDED across engines: libssl/libcrypto (openssl 3), libz, plus
    # autoPatchelf's default glibc set (libc, libm, libgcc_s, interpreter).
    buildInputs = [openssl zlib stdenv.cc.cc.lib];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/bin
      gzip -dc ${queryGz}  > $out/lib/libquery_engine.so.node
      gzip -dc ${schemaGz} > $out/bin/schema-engine
      chmod +x $out/bin/schema-engine
      chmod +x $out/lib/libquery_engine.so.node
      runHook postInstall
    '';

    # autoPatchelfHook fails the build on any unresolved lib: the patch gate.
    meta = {
      description = "Prisma 6.6.0 query + schema engines patched for NixOS";
      platforms = ["x86_64-linux" "aarch64-linux"];
    };
  }
