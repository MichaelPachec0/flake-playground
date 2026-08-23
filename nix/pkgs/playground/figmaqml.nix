# mmertama/FigmaQML: a Qt6/QML desktop app that converts Figma documents into
# QML, built from the nvfetcher-pinned latest GitHub release (`source` = an
# entry from ./_sources/generated.nix). Not in nixpkgs.
#
# Also usable headless: --help documents a real CLI (a token/output argument
# pair, --snap, --render-frame, --imports), so mainProgram is not decoration.
{
  lib,
  stdenv,
  bash,
  binutils,
  cmake,
  coreutils,
  fontconfig,
  libGL,
  ninja,
  openssl,
  qt6,
  symlinkJoin,
  source,
}: let
  # A coherent Qt prefix for the Execute feature to build against at RUNTIME.
  # Internal to this package on purpose: it is not a flake output and nothing
  # else should depend on its layout.
  #
  # It exists because nixpkgs' qt-cmake only points CMAKE_TOOLCHAIN_FILE at
  # qtbase's own qt.toolchain.cmake, making exactly ONE prefix visible -- so
  # find_package(Qt6 COMPONENTS Quick) cannot see qtdeclarative, which is a
  # separate store path. QT_ADDITIONAL_PACKAGES_PREFIX_PATH, which
  # qt.toolchain.cmake:154 advertises for precisely this case, does NOT work:
  # Qt's relocatability guard rejects the prefix with "expected and computed
  # paths are different". Joining the prefixes is what does work.
  #
  # libGL is here for WrapOpenGL: inside a nix build that resolves because the
  # cmake setup-hook seeds CMAKE_PREFIX_PATH from buildInputs, but at runtime
  # nothing does, and every OPENGL_* cache variable comes back -NOTFOUND.
  #
  # This set is minimal, verified by subtraction: an earlier working version
  # also carried qt6.qtshadertools and xorg.libX11{,.dev}, and removing them
  # still reaches "[27/27] Linking CXX executable app_figma". Do not add to it
  # speculatively.
  qtSdk = symlinkJoin {
    name = "figmaqml-qt-sdk";
    paths = [qt6.qtbase qt6.qtdeclarative libGL.dev libGL];
  };
in
  stdenv.mkDerivation {
    inherit (source) pname src;
    # strip leading v from nvfetcher version since fetchfromgithub will add it
    version = lib.removePrefix "v" source.version;

    nativeBuildInputs = [
      cmake
      ninja
      # Pulls in makeWrapper as well, which is why there is no explicit
      # makeWrapper here; qtWrapperArgs is the supported way to reach it.
      qt6.wrapQtAppsHook
    ];

    buildInputs = [
      qt6.qtbase
      qt6.qtdeclarative
      # Required, not optional: CMakeLists.txt:39-46 adds Qt6::SerialPort when
      # HAS_QUL AND HAS_EXECUTE, and both are true on Linux (HAS_QUL defaults TRUE
      # at line 20, HAS_EXECUTE is set unconditionally under `if(LINUX)` at 36-38).
      qt6.qtserialport
      # Configure-time only. CMakeLists.txt:249 does find_package(OpenSSL
      # REQUIRED), but lines 249-254 are just that plus a version message(WARNING):
      # OpenSSL appears in no target_link_libraries, so it adds nothing to the
      # runtime closure. HTTPS to api.figma.com rides on Qt's TLS plugin, which
      # wrapQtAppsHook wires up.
      #
      # qt6.qt5compat is deliberately absent. The only QML file importing
      # Qt5Compat.GraphicalEffects is qml/QtDropShadow.qml, which is referenced by
      # no .qrc and no source file anywhere in the tree: dead code. The parser's
      # emitted import (src/figmaqml.cpp:337,393) is #ifdef QT5COMPAT guarded, and
      # with the option off it emits QtQuick.Effects from qtdeclarative instead.
      openssl
    ];

    # CMAKE_BUILD_TYPE is deliberately absent: the nixpkgs cmake hook already
    # defaults to Release.
    cmakeFlags = [
      # MANDATORY, not an optimisation. CMakeLists.txt:181-183 runs
      # FetchContent_Declare(cmakedoc GIT_REPOSITORY https://...) under
      # `if(LINUX AND NOT NO_DOC)`. That is a network fetch during configure,
      # which the Nix sandbox denies. Doxygen and aspell are not needed either
      # once this is off.
      "-DNO_DOC=ON"
      # Already the upstream default (CMakeLists.txt:20); set explicitly to
      # document the choice. Qt for MCU project *export* works; MCU *execution*
      # needs a commercial SDK that cannot live in the store, and is left to a
      # user-supplied path.
      "-DHAS_QUL=ON"
    ];

    # The Execute feature shells out at runtime, so the app's own environment is
    # the build environment for the generated project.
    #
    # bash and coreutils are not garnish: app_figma/build.sh calls mkdir,
    # qt-cmake calls dirname, and executeApp.cpp invokes "bash" by bare name. A
    # launcher with a thin environment fails on `env: 'bash': No such file or
    # directory` before anything else. fontconfig covers src/fontinfo.cpp:41,
    # which spawns `fc-match --format=%{file}` to resolve Figma font names.
    #
    # CMAKE_PREFIX_PATH is the load-bearing export: it is what makes WrapOpenGL
    # resolve. The symlinkJoin alone does not, because nothing seeds
    # CMAKE_PREFIX_PATH at runtime the way the nixpkgs cmake setup-hook does at
    # build time.
    #
    # --prefix, NOT --set-default. --set-default assigns only when the variable is
    # unset, so launching FigmaQML from a `nix develop` shell (where the cmake
    # setup-hook has already exported CMAKE_PREFIX_PATH) would leave this join
    # invisible and Execute would fail with exactly the WrapOpenGL error above.
    # --prefix prepends ours and keeps the user's.
    #
    # There is deliberately NO QT_DIR export. It would be inert: executeApp.cpp:50
    # reads the dialog's qtDir parameter, line 52 does env.insert("QT_DIR",
    # qt_dir), overwriting anything inherited, and the qt-cmake search at line 53
    # uses that same dialog string rather than the environment. Nothing on the
    # desktop Execute path reads $QT_DIR: neither app_figma/build.sh nor nixpkgs'
    # qt-cmake does. What actually points Execute at a usable Qt is the QML
    # default patched below.
    #
    # Accepted cost: a C++ toolchain and a second Qt prefix in the runtime
    # closure, on the order of a gigabyte. That is the price of Execute working
    # out of the box, and it was chosen knowingly.
    qtWrapperArgs = [
      "--prefix PATH : ${lib.makeBinPath [
        qtSdk
        cmake
        ninja
        stdenv.cc
        binutils
        coreutils
        bash
        fontconfig
      ]}"
      "--prefix CMAKE_PREFIX_PATH : ${qtSdk}"
    ];

    postPatch = ''
      # Qt 6.11 annotated QFile::open with QFILE_MAYBE_NODISCARD, so this 2025
      # codebase no longer compiles under -Werror:
      #   src/figmaqml.cpp:1189:11: error: ignoring return value of
      #   'virtual bool QFile::open(QIODeviceBase::OpenMode)', declared with
      #   attribute 'nodiscard' [-Werror=unused-result]
      # The cause is Qt, not the compiler; upstream was pinned against 6.4-6.8.
      substituteInPlace CMakeLists.txt \
        --replace-fail " -Werror)" ")"

      # Same flag, but in the app that Execute compiles at RUNTIME.
      # app_figma/app.qrc embeds CMakeLists.txt, build.sh, qml.qrc, main.cpp and
      # the FigmaQmlInterface sources into the FigmaQML binary as Qt resources;
      # ExecuteUtils::copy_resources writes them to a temp dir and
      # AppWrite::executeApp builds them there. So this -Werror is evaluated
      # against whatever Qt and compiler the wrapper supplies, with no build-time
      # signal if a future combination trips it. It compiles clean today; this is
      # precautionary.
      substituteInPlace app_figma/CMakeLists.txt \
        --replace-fail " -Werror)" ")"

      # The Execute dialog defaults its "Qt DIR" field to /opt/Qt, which never
      # exists on NixOS, so executeApp.cpp:51 (VERIFY(QDir(qt_dir).exists(), ...))
      # rejects it before anything else runs. Point it at the join above. This
      # string is embedded in the binary via qml.qrc, so the store path is a real
      # reference and the join stays in the closure.
      substituteInPlace qml/QtForDesktopPopup.qml \
        --replace-fail 'text: "/opt/Qt"' 'text: "${qtSdk}"'

      # Drop the Qt.labs.settings alias that persists that field. Otherwise the
      # store path is written to the user's config on first run and survives every
      # later upgrade; after a qtbase bump plus a garbage collection the saved
      # path dangles and Execute fails with a stale-path error whose cause is
      # invisible to the user. Without the alias the field resets to the patched
      # default each session; a typed override still works, it just does not
      # persist.
      #
      # qml/QtForMCUPopup.qml has the same two lines and is deliberately left
      # alone: its qtDir points at a commercial SDK that cannot be in the store,
      # so a user-supplied, persisted path is the only correct value there.
      substituteInPlace qml/QtForDesktopPopup.qml \
        --replace-fail 'property alias qtDirValue: qtDir.text' \
                       '// qtDirValue alias removed: see the nix postPatch'
    '';

    # Upstream ships no install() rules anywhere (root, app_figma, and
    # app_figma/FigmaQmlInterface all checked); it deploys with linuxdeployqt. The
    # binary lands at the build-dir root.
    installPhase = ''
      runHook preInstall

      install -Dm755 FigmaQML $out/bin/FigmaQML

      runHook postInstall
    '';

    # These assertions are the test suite. Keeping them inside the derivation
    # means `nix build` is the test run, and the CI aggregate
    # (checks.x86_64-linux.playground) inherits every one of them for free.
    #
    # installCheckPhase runs AFTER fixupPhase, so wrapQtAppsHook has already
    # replaced $out/bin/FigmaQML with a wrapper by this point.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      test -x $out/bin/FigmaQML

      # The Execute feature compiles a generated Qt project at runtime. These
      # assert the environment that makes that possible; see the comments on
      # qtSdk and qtWrapperArgs above for why each one is here.
      wrapper=$out/bin/FigmaQML
      grep -q "CMAKE_PREFIX_PATH" "$wrapper"
      grep -q "${qtSdk}" "$wrapper"

      # QT_DIR must NOT be exported. It would be inert: executeApp.cpp:52 does
      # env.insert("QT_DIR", qt_dir) from the dialog field, overwriting anything
      # inherited before the child ever sees it. Asserting its absence keeps a
      # future contributor from "restoring" it and believing it does something.
      if grep -q "QT_DIR" "$wrapper"; then
        echo "wrapper exports QT_DIR; it is inert, see the qtWrapperArgs comment" >&2
        exit 1
      fi

      # build.sh calls mkdir, qt-cmake calls dirname, executeApp.cpp starts
      # "bash" by bare name, and src/fontinfo.cpp:41 spawns fc-match.
      for d in "${cmake}/bin" "${ninja}/bin" "${stdenv.cc}/bin" \
               "${coreutils}/bin" "${bash}/bin" "${fontconfig}/bin"; do
        if ! grep -q "$d" "$wrapper"; then
          echo "wrapper PATH is missing $d" >&2
          exit 1
        fi
      done

      # Proves the QML engine finds every import the app uses
      # (QtQuick.Controls.Fusion, QtQuick.Dialogs, Qt.labs.settings, QtCore) under
      # the wrapper. The offscreen QPA plugin ships in qtbase, so this needs no
      # display; HOME is set because Qt.labs.settings wants somewhere to write.
      HOME=$TMPDIR QT_QPA_PLATFORM=offscreen $out/bin/FigmaQML --help > help.txt
      grep -q -- "--imports" help.txt

      runHook postInstallCheck
    '';

    meta = {
      description = "Generate QML from Figma documents";
      homepage = "https://github.com/mmertama/FigmaQML";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      mainProgram = "FigmaQML";
    };
  }
