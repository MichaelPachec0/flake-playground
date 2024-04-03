{ lib, python3, fetchFromGitHub, fetchPypi, libjack2, alsa-lib, qt5, gst_all_1
, rtmidi, ola, gobject-introspection, cairo, liblo, gnome3, libadwaita }:
let
  jack-client = python3.pkgs.buildPythonPackage rec {
    pname = "JACK-Client";
    version = "0.5.4";
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-3UopPjpum96Zclabm8RjCl/NT4B1bMWQ3lcsx0TlqEg=";
    };
    buildInputs = with python3.pkgs; [ numpy cffi ] ++ [ libjack2 ];
  };
  pyalsa = python3.pkgs.buildPythonPackage rec {
    pname = "pyalsa";
    version = "1.2.7";
    src = fetchFromGitHub {
      owner = "alsa-project";
      repo = "alsa-python";
      # this is for tag v1.2.7
      rev = "v${version}";
      hash = "sha256-oldWPVtRAL81VZmftnEr7DhmDONpXZkBr91tfII/m2Y=";
    };
    buildInputs = [ alsa-lib ];
  };
in python3.pkgs.buildPythonApplication rec {
  pname = "linux-show-player";
  version = "0.6.2";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "FrancescoCeruti";
    repo = "linux-show-player";
    rev = "v${version}";
    hash = "sha256-vaYnB7/FZAIql2LPd9QlLV5PVQEtSiPIoU0N1xN+VBM=";
  };

  buildInputs = [ qt5.qtwayland ];
  nativeBuildInputs = [
    python3.pkgs.poetry-core
    qt5.wrapQtAppsHook
    libadwaita
    gnome3.adwaita-icon-theme
  ];

  propagatedBuildInputs = (with python3.pkgs; [
    appdirs
    cython
    falcon
    humanize
    jack-client
    mido
    pyalsa
    pygobject3
    pyliblo
    pyqt5
    python-rtmidi
    requests
    sortedcontainers
    packaging
  ]) ++ [ gobject-introspection cairo liblo rtmidi ola libjack2 ]
    ++ (with gst_all_1; [
      gstreamer
      gst-plugins-good
      gst-plugins-ugly
      gst-plugins-bad
      gst-libav
      gst-plugins-base
    ]);

  dontWrapQtApps = true;
  makeWrapperArgs = [ "\${qtWrapperArgs[@]}" ];
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
