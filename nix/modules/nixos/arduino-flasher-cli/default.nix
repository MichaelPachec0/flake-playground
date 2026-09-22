# NixOS module for arduino-flasher-cli (Arduino UNO Q image flasher).
# flake-playground convention: `import ./arduino-flasher-cli inputs` -> a NixOS
# module. There is no service here: this installs the CLI and, more usefully,
# the udev rule that lets it run without root.
#
# The tool shells out to an embedded qdl, which talks to the board over raw USB
# with libusb. A board held in Qualcomm Emergency Download mode enumerates as
# 05c6:9008 ("Qualcomm HS-USB QDLoader 9008"), owned by root with mode 0664 by
# default, so an unprivileged qdl fails with a libusb access error. TAG+="uaccess"
# hands the device to the user of the active local seat, the same approach the
# zsa module uses for keyboard flashing.
#
# Only the EDL device needs a rule. The board serial that `--serial` selects is
# read by qdl over that same USB interface, not from a tty, so no ttyACM rule is
# involved.
inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.arduino-flasher-cli;

  rules =
    ''
      # Qualcomm HS-USB QDLoader 9008: an UNO Q sitting in EDL mode, which is
      # what qdl flashes. uaccess grants the active local seat's user access.
      SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", ATTR{idProduct}=="9008", TAG+="uaccess"
    ''
    + lib.optionalString (cfg.group != null) ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", ATTR{idProduct}=="9008", MODE="0660", GROUP="${cfg.group}"
    ''
    + cfg.extraUdevRules;
in {
  options.programs.arduino-flasher-cli = {
    enable = lib.mkEnableOption "arduino-flasher-cli, Arduino's UNO Q image flasher";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.arduino-flasher-cli;
      defaultText = lib.literalExpression "self.packages.\${system}.arduino-flasher-cli";
      description = "The arduino-flasher-cli package to install.";
    };

    udevRules = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install a udev rule granting access to a board in Qualcomm EDL mode
        (05c6:9008). Without it, flashing only works as root.
      '';
    };

    group = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "plugdev";
      description = ''
        Additionally grant the EDL device to this group. Needed when flashing
        from somewhere uaccess does not cover, such as an SSH session or a
        headless machine with no local seat. The group is not created here.
      '';
    };

    extraUdevRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra udev rules appended to the generated file, for board variants that enumerate with other USB IDs.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    services.udev.packages = lib.optional cfg.udevRules (
      pkgs.writeTextFile {
        name = "arduino-flasher-cli-udev-rules";
        text = rules;
        destination = "/etc/udev/rules.d/60-arduino-flasher-cli.rules";
      }
    );
  };
}
