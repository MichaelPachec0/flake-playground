# Retention: the hourly pruner (unprivileged, decides roots) and the GC
# (root, deletes what nothing roots). They share /var/lib/nix-cache/lock with
# the importer, so GC never runs between an import and its pin.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nix-cache-host;
  hardening = import ./hardening.nix;
in {
  config = lib.mkIf cfg.enable {
    systemd.services.cache-pruner = {
      description = "Plan nix-cache retention and update its GC roots";
      # The pruner resolves nix and nix-store from PATH.
      path = [config.nix.package];
      unitConfig = {
        OnSuccess = ["cache-gc.service"];
        OnFailure = ["nix-cache-unit-failed@%n.service"];
      };
      serviceConfig =
        hardening
        // {
          Type = "oneshot";
          User = "nix-cache";
          Group = "nix-cache";
          # Reads nginx's access log (0640 nginx:nginx).
          SupplementaryGroups = [config.services.nginx.group];
          ExecStart = "${lib.getExe' cfg.package "cache-pruner"} --config ${cfg.configFile}";
          ReadWritePaths = [
            "/nix/var/nix/gcroots/cache"
            "/var/lib/nix-cache"
          ];
          MemoryMax = "2G";
        };
    };

    systemd.timers.cache-pruner = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "hourly";
        RandomizedDelaySec = "5m";
        Persistent = true;
      };
    };

    systemd.services.cache-gc = {
      description = "Collect store paths that no nix-cache pin or keep root references";
      unitConfig.OnFailure = ["nix-cache-unit-failed@%n.service"];
      serviceConfig = {
        Type = "oneshot";
        Nice = 19;
        IOSchedulingClass = "idle";
        ExecStart = "${pkgs.util-linux}/bin/flock /var/lib/nix-cache/lock ${config.nix.package}/bin/nix-store --gc";
      };
    };
  };
}
