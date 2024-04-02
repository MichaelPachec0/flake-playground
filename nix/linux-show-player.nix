{
  lib,
  python3Packages,
  fetchFromGitHub,
  fetchPypi,
  # NOTE: non py deps
  gst_all_1,
  alsa-lib,
  gobject-introspection,
  cairo,
  liblo,
  rtmidi,
  ola,
  qt5,
  libjack2,
  # jack2,
  gnome3,
  libadwaita,
}: let
  pyalsa = python3Packages.buildPythonPackage {
    pname = "pyalsa";
    version = "v1.2.7";
    src = fetchFromGitHub {
      owner = "alsa-project";
      repo = "alsa-python";
      # this is for tag v1.2.7
      rev = "7d6dfe0794d250190a678312a2903cb28d46622b";
      hash = "sha256-oldWPVtRAL81VZmftnEr7DhmDONpXZkBr91tfII/m2Y=";
    };
    buildInputs = [
      alsa-lib
    ];
  };
  jack-client = python3Packages.buildPythonPackage rec {
    pname = "JACK-Client";
    version = "0.5.4";
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-3UopPjpum96Zclabm8RjCl/NT4B1bMWQ3lcsx0TlqEg=";
    };
    buildInputs = with python3Packages;
      [
        numpy
        cffi
      ]
      ++ [libjack2];
  };
in
  python3Packages.buildPythonPackage rec {
    pname = "linux-show-player";
    version = "0.6.2";
    pyproject = true;

    src = fetchFromGitHub {
      owner = "FrancescoCeruti";
      repo = pname;
      rev = "v${version}";
      hash = "sha256-vaYnB7/FZAIql2LPd9QlLV5PVQEtSiPIoU0N1xN+VBM=";
    };
    buildInputs = [
      gnome3.adwaita-icon-theme
      libadwaita
      qt5.wrapQtAppsHook
      qt5.qtwayland
    ];
    nativeBuildInputs =
      [
        qt5.wrapQtAppsHook
        python3Packages.poetry-core
      ]
      ++ (with gst_all_1; [
        gstreamer
        gst-plugins-good
        gst-plugins-ugly
        gst-plugins-bad
        gst-libav
        gst-plugins-base
      ]);
    propagatedNativeBuildInputs =
      [
        alsa-lib
        gobject-introspection
        cairo
        liblo
        rtmidi
        libjack2
        ola
      ]
    ;
    propagatedBuildInputs =
      [
        alsa-lib
        gobject-introspection
        cairo
        liblo
        rtmidi
        ola
        libjack2
      ]
      # ++ (with gst_all_1; [
      #   gstreamer
      #   gst-plugins-good
      #   gst-plugins-ugly
      #   gst-plugins-bad
      #   gst-libav
      #   gst-plugins-base
      # ])
      ++ (with python3Packages; [
        appdirs
        cython
        falcon
        mido
        pygobject3
        pyqt5
        python-rtmidi
        requests
        sortedcontainers
        humanize
        pyliblo
        pyalsa
        jack-client
        gst-python
        packaging
      ]);
    # strictDeps = false;

    dontWrapQtApps = true;
    makeWrapperArgs = [
      "\${qtWrapperArgs[@]}"
    ];
    # preFixup = ''
    #   wrapQtApp "$out/bin/linux-show-player" --prefix PATH:
    # makeWrapperArgs+=("''${qtWrapperArgs[@]}")
    # makeWrapperArgs+=(--prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "$GST_PLUGIN_SYSTEM_PATH_1_0")
    # makeWrapperArgs+=(--prefix PATH : "${gst_all_1.gst-plugins-good}")
    # '';
  }
# gst_all_1.gst-libav,
#   gst_all_1.gst-plugins-bad,
#   gst_all_1.gst-plugins-ugly,

