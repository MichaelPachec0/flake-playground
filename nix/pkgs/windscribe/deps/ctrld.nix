{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "ctrld";
  version = "1.5.0";
  src = pkgs.fetchurl {
    url = "https://github.com/Control-D-Inc/ctrld/releases/download/v1.5.0/ctrld_1.5.0_linux_amd64.tar.gz";
    hash = "sha256-rMFSeKxJ/3ENsVlgKiBIC411/nv4PEQjufTthFx0USc=";
  };
  sourceRoot = ".";
  nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.upx ];
  # ctrld is a UPX-compressed Go binary that links against glibc at runtime
  buildInputs = [ pkgs.glibc ];
  installPhase = ''
    install -Dm755 dist/ctrld_1.5.0_linux_amd64/ctrld $out/bin/ctrld
    upx -d $out/bin/ctrld
  '';
}
