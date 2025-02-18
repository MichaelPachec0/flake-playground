inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  check = config.hardware.cynthion.enable;
  inherit (pkgs.stdenv.hostPlatform) system;
  text = ''
    # Configures Linux to allow access to Cynthion hardware for anyone logged into the physical terminal.
    #
    #     # install udev rules
    #     sudo cp 54-cynthion.rules /etc/udev/rules.d
    #
    #     # reload udev rules
    #     sudo udevadm control --reload
    #
    #     # apply udev rules to any devices that are already plugged in
    #     sudo udevadm trigger

    SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="615b", SYMLINK+="cynthion-%k", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="615c", SYMLINK+="cynthion-apollo-%k", TAG+="uaccess"

    SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="000a", SYMLINK+="cynthion-test-%k", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="000e", SYMLINK+="cynthion-example-%k", TAG+="uaccess"
  '';
in {
  options = {
    hardware.cynthion = {
      enable = lib.mkEnableOption "Enable cynthion hardware support";
    };
  };
  config =
    {}
    // (lib.mkIf check {
      environment.systemPackages = [
        inputs.self.packages.${system}.cynthion
      ];
      services.udev = {
        packages = [
          (pkgs.writeTextFile {
            inherit text;
            name = "cynthion rules";
            destination = "/etc/udev/rules.d/54-cynthion.rules";
          })
        ];
      };
    });
}
