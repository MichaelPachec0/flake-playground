{ pkgs, devMode ? false }:
let
  wsnetSrc = import ./deps/wsnet.nix { inherit pkgs; };
  small = import ./deps/small/default.nix { inherit pkgs; };

  # Windscribe Desktop C++ source, tag v2.23.9 (= master @ 82503fdb on the official repo).
  # src/ is pristine at this tag, so the build-time patches below apply cleanly.
  wsSrc = pkgs.fetchFromGitHub {
    owner = "Windscribe";
    repo = "Desktop-App";
    rev = "v2.23.9";
    hash = "sha256-VmhIDGXKQnwjuQewQuGII/BjqswhWuudkQNmP7F/NvQ=";
  };

  # DNS / network helper scripts the helper invokes from WS_LINUX_INSTALL_DIR/scripts.
  scriptsDir = "${wsSrc}/src/installer/windscribe/linux/opt/windscribe/scripts";

  wstunnel = import ./deps/wstunnel.nix { inherit pkgs; };
  ctrld = import ./deps/ctrld.nix { inherit pkgs; };
  openvpn-ws = import ./deps/openvpn-ws.nix { inherit pkgs; };

  # nixpkgs curl does not ship a CURLConfig.cmake — write a shim so wsnet's
  # find_package(CURL CONFIG REQUIRED) resolves to CURL::libcurl.
  curlCmakeShim = pkgs.writeTextDir "lib/cmake/CURL/CURLConfig.cmake" ''
    if(NOT TARGET CURL::libcurl)
      add_library(CURL::libcurl SHARED IMPORTED)
      set_target_properties(CURL::libcurl PROPERTIES
        IMPORTED_LOCATION "${pkgs.curlEch.out}/lib/libcurl.so"
        INTERFACE_INCLUDE_DIRECTORIES "${pkgs.curlEch.dev}/include"
        INTERFACE_LINK_LIBRARIES "OpenSSL::SSL;OpenSSL::Crypto"
      )
    endif()
    set(CURL_FOUND TRUE)
    set(CURL_LIBRARIES CURL::libcurl)
    set(CURL_INCLUDE_DIRS "${pkgs.curlEch.dev}/include")
    # Keep in sync with the curlEch version defined in nix/overlay.nix.
    set(CURL_VERSION_STRING "8.19.0")
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "windscribe";
  version = "2.23.9";
  src = wsSrc;
  patches = [ ./patches/cmake-system-deps.patch ./patches/source-native-fixes.patch ];

  # In prod mode, make WS_LINUX_INSTALL_DIR a CACHE variable so the cmake -D flag
  # (which creates a cache entry) takes precedence over the plain set() in windscribe.cmake.
  # Without this, set(WS_LINUX_INSTALL_DIR "/opt/windscribe") creates a normal variable that
  # shadows the cache entry, so -DWS_LINUX_INSTALL_DIR=... has no effect.
  postPatch = pkgs.lib.optionalString (!devMode) ''
    substituteInPlace cmake/integrations/windscribe.cmake \
      --replace-fail \
      'set(WS_LINUX_INSTALL_DIR "/opt/windscribe")' \
      'set(WS_LINUX_INSTALL_DIR "/opt/windscribe" CACHE STRING "")'
  '';

  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    pkg-config
    qt6.wrapQtAppsHook
    qt6.qttools
    patchelf
  ];

  buildInputs = (with pkgs; [
    qt6.qtbase
    qt6.qtsvg
    qt6.qtwayland
    qt6.qtimageformats
    boost
    fmt
    gtest
    rapidjson
    pkgs.opensslEch
    pkgs.curlEch
    pkgs.spdlogWs
    pkgs.caresWs
    nlohmann_json
    protobuf
    acl
    curlCmakeShim
  ]) ++ (builtins.attrValues small);

  cmakeFlags = [
    "-DWS_USE_SYSTEM_DEPS=ON"
    "-DBUILD_APP=ON"
    "-DBUILD_INSTALLER=OFF"
    "-DBUILD_DEB=OFF"
    "-DBUILD_RPM=OFF"
    "-DBUILD_RPM_OPENSUSE=OFF"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DFETCHCONTENT_SOURCE_DIR_WSNET=${wsnetSrc}"
    "-DOPENSSL_ROOT_DIR=${pkgs.opensslEch.out}"
    "-DOPENSSL_USE_STATIC_LIBS=ON"
  ] ++ (if devMode
  then [ "-DDEV_MODE=ON" ]
  else [
    "-DDEV_MODE=OFF"
    # Point the install-dir macro at $out/bin — the GUI binary's own directory. This makes the
    # helper's WS_LINUX_INSTALL_DIR coincide with the client engine's applicationDirPath()
    # (openvpnversioncontroller.cpp resolves windscribeopenvpn relative to the GUI binary), exactly
    # as the upstream .deb's single /opt/windscribe dir does. realpath() of this store path
    # canonicalizes to itself, so the helper's non-dev path check passes with no symlink indirection.
    "-DWS_LINUX_INSTALL_DIR=${placeholder "out"}/bin"
  ]);

  # Build only the Linux app target (GUI + CLI + helper).
  ninjaFlags = [ "build-app" ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib

    # GUI + CLI + helper, discovered from the build tree (cmakeBuildDir=build, search from '.').
    for b in Windscribe windscribe-cli helper; do
      f=$(find . -maxdepth 4 -type f -name "$b" -perm -u+x | head -1)
      if [ -z "$f" ]; then
        echo "ERROR: could not find built binary '$b'" >&2
        exit 1
      fi
      dest="$b"
      [ "$b" = "helper" ] && dest="windscribe-helper"
      install -Dm755 "$f" "$out/bin/$dest"
    done

    # libwsnet.so is built in-tree and linked by the app/cli (RPATH fixed up in preFixup).
    wsnetlib=$(find . -maxdepth 4 -type f -name 'libwsnet.so*' | head -1)
    if [ -z "$wsnetlib" ]; then
      echo "ERROR: could not find built libwsnet.so" >&2
      exit 1
    fi
    install -Dm755 "$wsnetlib" "$out/lib/libwsnet.so"
  '' + (pkgs.lib.optionalString devMode ''
    # DEV layout: bundled binaries under $out/lib/windscribe. NOT runtime-reachable
    # (helper's WS_LINUX_INSTALL_DIR stays the /opt default in dev) — for GUI/CLI poking only.
    mkdir -p $out/lib/windscribe
    install -Dm755 ${wstunnel}/bin/wstunnel    $out/lib/windscribe/wstunnel
    install -Dm755 ${ctrld}/bin/ctrld          $out/lib/windscribe/ctrld
    install -Dm755 ${openvpn-ws}/bin/openvpn   $out/lib/windscribe/openvpn
  '') + ''
    runHook postInstall
  '';
  # NOTE (prod): the bundled binaries, DNS scripts, and Qt plugins all live in $out/bin
  # (= WS_LINUX_INSTALL_DIR = applicationDirPath). They are materialized in postFixup, NOT here,
  # so wrapQtAppsHook (a fixupOutputHook that wraps every executable under $out/bin) cannot turn
  # them into makeBinaryWrapper stubs.

  # CMake records an RPATH into the in-tree wsnet build dir (/build/.../_deps/
  # wsnet-build), which Nix forbids. Strip any /build/ entries from the RPATH and
  # point the binaries at $out/lib where libwsnet.so is installed. Runs before the
  # fixup phase's RPATH shrink/forbidden-reference check.
  preFixup = ''
    for b in $out/bin/Windscribe $out/bin/windscribe-cli $out/bin/windscribe-helper $out/lib/libwsnet.so; do
      [ -e "$b" ] || continue
      old=$(patchelf --print-rpath "$b" 2>/dev/null || true)
      new=$(echo "$old" | tr ':' '\n' | grep -v '^/build/' | grep -v '^$' | paste -sd: -)
      if [ -n "$new" ]; then
        patchelf --set-rpath "$new:$out/lib" "$b" || true
      else
        patchelf --set-rpath "$out/lib" "$b" || true
      fi
    done
  '';

  # Prod runtime tree, all under $out/bin (= WS_LINUX_INSTALL_DIR = the GUI's applicationDirPath).
  # MUST run in postFixup, not installPhase: wrapQtAppsHook is a fixupOutputHook that wraps every
  # executable under $out/bin; placed earlier, the bundled-binary symlinks and the plugin .so files
  # (cp -rs leaves them +x) would each be replaced by a makeBinaryWrapper stub — Qt then rejects the
  # plugin stubs, and the helper/engine would exec wrapper shims. postFixup runs after that hook.
  postFixup = pkgs.lib.optionalString (!devMode) ''
    # Bundled VPN helpers, under the 'windscribe'-prefixed names resolveExePath() (helper) and
    # OpenVpnVersionController (engine) expect. Symlinks suffice — neither side realpaths the file.
    ln -s ${openvpn-ws}/bin/openvpn  $out/bin/windscribeopenvpn
    ln -s ${wstunnel}/bin/wstunnel   $out/bin/windscribewstunnel
    ln -s ${ctrld}/bin/ctrld         $out/bin/windscribectrld

    # DNS / network helper scripts (WS_LINUX_INSTALL_DIR/scripts); shebangs rewritten to store paths.
    mkdir -p $out/bin/scripts
    for s in update-systemd-resolved update-resolv-conf update-network-manager dns-leak-protect gai-ipv4-priority; do
      install -Dm755 ${scriptsDir}/$s $out/bin/scripts/$s
    done
    patchShebangs $out/bin/scripts

    # Merged Qt plugin tree: the non-dev GUI pins Qt plugin search to applicationDirPath()/plugins
    # and discards QT_PLUGIN_PATH (main.cpp). Covers platforms (launch), tls/libqopensslbackend
    # (QSslSocket), and imageformats/iconengines/wayland-* for the UI.
    mkdir -p $out/bin/plugins
    for qp in ${pkgs.qt6.qtbase} ${pkgs.qt6.qtsvg} ${pkgs.qt6.qtwayland} ${pkgs.qt6.qtimageformats}; do
      cp -rs $qp/lib/qt-6/plugins/. $out/bin/plugins/
      chmod -R u+w $out/bin/plugins
    done
  '';

  meta = {
    description = "Windscribe Desktop VPN — native build (Nix-provided deps)";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    # The GUI binary is `Windscribe` (capital W, upstream CMake target name),
    # not the lowercase pname. Without this, `nix run .#windscribe` looks for
    # $out/bin/windscribe and fails with ENOENT.
    mainProgram = "Windscribe";
  };
}
