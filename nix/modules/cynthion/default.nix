inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  module = "cynthion";
  priority = "54";
  cfg = config.hardware.${module};
  # TODO: instead of hardcoding, pull it from cynthion pkg, so as not need to track changes here.
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
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enables ${module} udev rules to use the ${module} as non-root.
          Also installs the prerequisite software to update and check the status of the ${module}.
        '';
      };
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      # We are using NixOS, make sure that the software knows that we are doing so.
      # Negative to this is that this wont be cached, but its better for either NixOS users getting errors
      # when execing "cynthion setup"
      (inputs.self.packages.${system}.${module}.override
        {nixosInstall = true;})
    ];
    services.udev = {
      packages = [
        # TODO: make this a pkg?, hackrf is a package, so it can be setup without the module.
        (pkgs.writeTextFile {
          inherit text;
          name = "${module} rules";
          destination = "/etc/udev/rules.d/${priority}-${module}.rules";
        })
      ];
    };
  };
}
