{ lib, python3, fetchFromGitHub, fetchPypi, libjack2, alsa-lib, qt5, gst_all_1
, rtmidi, ola, gobject-introspection, cairo, liblo, libadwaita, wrapGAppsHook3 }:
let
  jack-client = python3.pkgs.buildPythonPackage rec {
    pname = "JACK-Client";
    version = "0.5.4";
    pyproject = true;
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-3UopPjpum96Zclabm8RjCl/NT4B1bMWQ3lcsx0TlqEg=";
    };
    build-system = [ python3.pkgs.setuptools ];
    # find_library('jack') can't locate libjack in the Nix store (no ldconfig
    # cache), so pin the absolute path; this also pulls libjack2 into the closure.
    postPatch = ''
      substituteInPlace src/jack.py \
        --replace-fail "_libname = _find_library('jack')" \
          "_libname = '${libjack2}/lib/libjack.so'"
    '';
    # numpy/cffi are needed at runtime (cffi provides the _cffi_backend module).
    dependencies = with python3.pkgs; [ numpy cffi ];
    buildInputs = [ libjack2 ];
  };
  pyalsa = python3.pkgs.buildPythonPackage rec {
    pname = "pyalsa";
    # Upstream pins a specific commit; v1.2.12 == f8f9260282eb9c97f53e4689e04182dc87a4810e
    version = "1.2.12";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "alsa-project";
      repo = "alsa-python";
      rev = "v${version}";
      hash = "sha256-a0hqYg4VE6L6PBPZW5aGPa5L16uI9eHGvoyZPMkqsMU=";
    };
    build-system = [ python3.pkgs.setuptools ];
    buildInputs = [ alsa-lib ];
  };
  # Upstream pins the FrancescoCeruti fork because it keeps the legacy `liblo`
  # module name; nixpkgs' pyliblo3 exposes the bindings as `pyliblo3` instead,
  # which the OSC plugin's `from liblo import ...` can't find.
  pyliblo3 = python3.pkgs.buildPythonPackage rec {
    pname = "pyliblo3";
    version = "0.13.0";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "FrancescoCeruti";
      repo = "pyliblo3";
      rev = "9b66f93bc058807fdbe27f9255b18b0df8e60e32";
      hash = "sha256-wCU3FAPV9uXY8/We1gfLvXw4JEcxd4IsKUd1+YqGa7w=";
    };
    build-system = with python3.pkgs; [ setuptools cython ];
    # The .pyx uses the Py2 `long` builtin, which Cython 3 (language_level=3)
    # rejects; `int` is the Py3 equivalent.
    postPatch = ''
      substituteInPlace src/liblo.pyx \
        --replace-fail "long(value)" "int(value)" \
        --replace-fail "isinstance(value, (int, long))" "isinstance(value, int)" \
        --replace-fail "isinstance(t, (float, int, long))" "isinstance(t, (float, int))"
    '';
    # setup.py declares cython as a runtime dep, but the compiled `liblo`
    # extension doesn't import it; drop it so pythonRuntimeDepsCheck passes.
    pythonRemoveDeps = [ "cython" ];
    buildInputs = [ liblo ];
  };
  # Not yet packaged in nixpkgs; required since 0.6.5.
  qdigitalmeter = python3.pkgs.buildPythonPackage rec {
    pname = "qdigitalmeter";
    version = "0.1.0";
    pyproject = true;
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-N+Gwvp4KjuMt2UdRIwo3iR3aL1uMO9XKSTD8N+7Y42U=";
    };
    nativeBuildInputs = [ python3.pkgs.poetry-core ];
    propagatedBuildInputs = [ python3.pkgs.qtpy ];
  };
in python3.pkgs.buildPythonApplication rec {
  pname = "linux-show-player";
  version = "0.6.5";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "FrancescoCeruti";
    repo = "linux-show-player";
    rev = "v${version}";
    hash = "sha256-Py+w2U5mSBP2wqRhSTe3r/fvx4DfZIEeu3sp50a39EE=";
  };

  # Upstream declares pyqt5-qt5 (PyPI's prebuilt Qt5 binaries) as a runtime dep;
  # nixpkgs' pyqt5 bundles Qt itself, so drop it to satisfy pythonRuntimeDepsCheck.
  pythonRemoveDeps = [ "pyqt5-qt5" ];

  buildInputs = [ qt5.qtwayland gobject-introspection ];
  nativeBuildInputs = [
    python3.pkgs.poetry-core
    qt5.wrapQtAppsHook
    libadwaita
    wrapGAppsHook3
    gobject-introspection
  ];

  propagatedBuildInputs = (with python3.pkgs; [
    appdirs
    falcon
    humanize
    jack-client
    mido
    numpy
    pyalsa
    pygobject3
    pyliblo3
    pyqt5
    python-rtmidi
    qdigitalmeter
    requests
    sortedcontainers
    packaging
  ]) ++ (with gst_all_1; [
    gstreamer
    gst-plugins-good
    gst-plugins-ugly
    gst-plugins-bad
    gst-libav
    gst-plugins-base
  ]) ++ [ cairo liblo rtmidi ola ];

  # NOTE: assuming this is not the way to avoid double wrapping. This still works, so keep it for now.
  dontWrapQtApps = true;
  dontWrapGApps = true;
  makeWrapperArgs = [ "\${qtWrapperArgs[@]}" "\${gappsWrapperArgs[@]}" ];

  # TODO: fix this.
  # pythonImportsCheck = [ "linux_show_player" ];

  meta = with lib; {
    description =
      "Linux Show Player - Cue player designed for stage productions";
    homepage = "https://github.com/FrancescoCeruti/linux-show-player";
    license = licenses.gpl3Only;
    maintainers = with maintainers; [ MichaelPachec0 ];
    mainProgram = "linux-show-player";
    platforms = [ "x86_64-linux" ];
  };
}
