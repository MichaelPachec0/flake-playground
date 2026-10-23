# nix-cache: stdlib-only Python tooling for the self-hosted Nix binary cache.
# CI runs nix-cache-bundle; the cache host (services.nix-cache-host) runs
# cache-importer, cache-pruner and nix-cache-alert. The unit tests and the
# black-box CLI suite (tests/test_cli.py) run at build time, so a broken tool never
# reaches selene.
{
  lib,
  python3Packages,
  zstd,
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
    ];
  };

  build-system = [python3Packages.setuptools];

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
