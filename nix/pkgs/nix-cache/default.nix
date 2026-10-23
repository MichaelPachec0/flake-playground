# nix-cache: stdlib-only Python tooling for the self-hosted Nix binary cache.
# CI runs nix-cache-bundle; the cache host (services.nix-cache-host) runs
# cache-importer, cache-pruner and nix-cache-alert. The unit tests and the
# black-box CLI suite (tests/test_cli.py) run at build time, so a broken tool never
# reaches selene.
{
  lib,
  python3Packages,
  zstd,
  coreutils,
  findutils,
  gnutar,
  makeWrapper,
  runtimeShell,
}:
python3Packages.buildPythonApplication {
  pname = "nix-cache";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
      ./tests
      ./cache-receive.sh
      ./push-bundle.sh
    ];
  };

  build-system = [python3Packages.setuptools];

  nativeBuildInputs = [makeWrapper];

  # nix-cache-push-bundle is shell, not Python: the one copy of the upload
  # pipeline (tar exactly the members cache-receive accepts, zstd, pipe to
  # the given ssh command). Used by the VM test, the push workflow and
  # manual pushes.
  # The shebang is pinned here because the tests run before the fixup phase.
  postInstall = ''
    install -Dm755 ${./push-bundle.sh} $out/bin/nix-cache-push-bundle
    substituteInPlace $out/bin/nix-cache-push-bundle \
      --replace-fail '#!/usr/bin/env bash' '#!${runtimeShell}'
    wrapProgram $out/bin/nix-cache-push-bundle \
      --prefix PATH : ${lib.makeBinPath [coreutils findutils gnutar zstd]}
  '';

  # tests/test_cli.py is the black-box suite; point it at the installed tools.
  preInstallCheck = ''
    export NIX_CACHE_BIN=$out/bin
  '';

  nativeCheckInputs = [
    python3Packages.pytestCheckHook
    zstd
  ];

  # The importer unpacks bundles with the zstd binary: Python 3.13 (selene)
  # has no zstd module in the stdlib.
  makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [zstd])];

  pythonImportsCheck = ["nix_cache"];

  # The NixOS module builds one forced-command script per repo from this body.
  passthru.receiveScript = ./cache-receive.sh;

  meta = {
    description = "Bundler, importer, pruner and helpers for a self-hosted Nix binary cache";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "cache-importer";
  };
}
