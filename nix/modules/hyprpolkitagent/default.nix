{
  config,
  lib,
  pkgs,
  ...
}: let
  module = "hyprpolkitagent";
  cfg = config.services.${module};
in {
  options = {
    services.${module}.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enables ${module}. 
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # make sure polkit is enabled by default
    security.polkit.enable = lib.mkDefault true;

    systemd = {
      user.services.polkit-gnome-authentication-agent-1 = {
        description = "hyprpolkitagent";
        # Dont know if its reasonable to tie this to hyprland explicitly, but then this would mean that this
        # would enter HM land
        wantedBy = ["graphical-session.target"];
        wants = ["graphical-session.target"];
        after = ["graphical-session.target"];
        serviceConfig = {
          Type = "simple";
          # usr is not needed
          ExecStart = "${pkgs.${module}}/libexec/hyprpolkitagent";
          Restart = "on-failure";
          RestartSec = 1;
          TimeoutStopSec = 10;
        };
      };
    };
  };
}
