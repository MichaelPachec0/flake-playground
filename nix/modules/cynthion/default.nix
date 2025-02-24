inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  module = "cynthion";
  priority = "54";
  check = config.hardware.${module}.enable;
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
    hardware.${module} = {
      enable = lib.mkEnableOption "Enable ${module} hardware support";
    };
  };
  config =
    {}
    // (lib.mkIf check {
      environment.systemPackages = [
        (inputs.self.packages.${system}.${module}.override
          {nixosInstall = true;})
      ];
      services.udev = {
        packages = [
          (pkgs.writeTextFile {
            inherit text;
            name = "${module} rules";
            destination = "/etc/udev/rules.d/${priority}-${module}.rules";
          })
        ];
      };
    });
}
