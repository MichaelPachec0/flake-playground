# ElectronMail, an unofficial ProtonMail desktop client, packaged from the
# upstream prebuilt AppImage. `source` is an nvfetcher entry from ./_sources
# (tracking the latest GitHub *release*), giving the fetched AppImage (src),
# resolved version and pname. See ./nvfetcher.toml for the release-tracking
# config (note the `src.prefix = "v"` that strips the tag's `v` so the asset
# URL and version line up).
{
  appimageTools,
  lib,
  makeWrapper,
  libsecret,
  source,
}: let
  inherit (source) pname version src;
  appimageContents = appimageTools.extract {inherit pname version src;};
in
  appimageTools.wrapType2 {
    inherit pname version src;

    extraInstallCommands = ''
      source "${makeWrapper}/nix-support/setup-hook"
      wrapProgram $out/bin/${pname}\
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"
      install -m 444 -D ${appimageContents}/${pname}.desktop -t $out/share/applications
      substituteInPlace $out/share/applications/${pname}.desktop \
        --replace-fail 'Exec=AppRun' 'Exec=${pname}'
      cp -r ${appimageContents}/usr/share/icons $out/share
    '';

    extraPkgs = pkgs:
      with pkgs; [
        libsecret
        libappindicator-gtk3
      ];

    meta = {
      description = "Electron-based unofficial desktop client for ProtonMail";
      mainProgram = "electron-mail";
      homepage = "https://github.com/vladimiry/ElectronMail";
      license = lib.licenses.gpl3Only;
      platforms = ["x86_64-linux"];
    };
  }
