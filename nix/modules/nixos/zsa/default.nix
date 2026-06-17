inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  module = "zsa";
  priority = "54";
  cfg = config.hardware.${module};
  text = ''
    # Teensy rules for the Ergodox EZ Original / Shine / Glow
    ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", ENV{ID_MM_DEVICE_IGNORE}="1"
    ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789A]?", ENV{MTP_NO_PROBE}="1"
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789ABCD]?", TAG+="uaccess"
    KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", TAG+="uaccess"

    # STM32 rules for the Moonlander and Planck EZ Standard / Glow
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", TAG+="uaccess", SYMLINK+="stm32_dfu"
  '';
in {
  options = {
    hardware.${module} = {
      wally.enable = lib.mkEnableOption "Enable ${module} hardware support";
      oryx.enable = lib.mkEnableOption "Enable oryx hardware support";
      legacy.enable = lib.mkEnableOption "Enable oryx legacy hardware support";
    };
  };
  config = {
    services.udev = {
      packages =
        []
        ++ lib.optionals cfg.wally.enable [
          (pkgs.writeTextFile {
            inherit text;
            name = "${module} rules";
            destination = "/etc/udev/rules.d/${priority}-wally.rules";
          })
        ]
        ++ lib.optionals cfg.oryx.enable [
          (pkgs.writeTextFile {
            name = "oryx rules";
            text = ''
              # Rules for Oryx web flashing and live training
              KERNEL=="hidraw*", ATTRS{idVendor}=="16c0", MODE="0664", TAG+="uaccess"
              KERNEL=="hidraw*", ATTRS{idVendor}=="3297", MODE="0664", TAG+="uaccess"
            '';
            destination = "/etc/udev/rules.d/${priority}-orxy.rules";
          })
        ]
        ++ lib.optionals cfg.legacy.enable [
          (pkgs.writeTextFile {
            name = "legacy oryx";
            text = ''
              # Legacy rules for live training over webusb (Not needed for firmware v21+)
              # Rule for all ZSA keyboards
              SUBSYSTEM=="usb", ATTR{idVendor}=="3297", TAG+="uaccess"
              # Rule for the Moonlander
              SUBSYSTEM=="usb", ATTR{idVendor}=="3297", ATTR{idProduct}=="1969", TAG+="uaccess"
              # Rule for the Ergodox EZ
              SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="1307", TAG+="uaccess"
              # Rule for the Planck EZ
              SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="6060", TAG+="uaccess"
            '';
            destination = "/etc/udev/rules.d/${priority}-oryx-legacy.rules";
          })
        ];
    };
  };
}
