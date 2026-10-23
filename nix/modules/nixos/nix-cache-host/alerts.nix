# Alert delivery. Sandboxed units queue JSON files in /var/lib/nix-cache/alerts;
# this unit (network allowed) runs the configured command for each. Failed
# deliveries wait in alerts-deferred/ until the next pruner run requeues them.
{
  config,
  lib,
  ...
}: let
  cfg = config.services.nix-cache-host;
in {
  config = lib.mkIf cfg.enable {
    systemd.paths.nix-cache-alert = {
      wantedBy = ["paths.target"];
      pathConfig.DirectoryNotEmpty = "/var/lib/nix-cache/alerts";
    };

    systemd.services.nix-cache-alert = {
      description = "Deliver queued nix-cache alerts";
      serviceConfig = {
        Type = "oneshot";
        User = "nix-cache";
        Group = "nix-cache";
        LoadCredential = cfg.alerts.loadCredential;
        ExecStart = "${lib.getExe' cfg.package "nix-cache-alert"} --spool /var/lib/nix-cache/alerts --deferred /var/lib/nix-cache/alerts-deferred --command ${cfg.alerts.command}";
      };
    };

    systemd.services."nix-cache-unit-failed@" = {
      description = "Alert that %i failed";
      scriptArgs = "%i";
      script = ''
        ${config.systemd.package}/bin/journalctl -u "$1" -n 40 --no-pager | ${cfg.alerts.command} "nix-cache: $1 failed"
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "nix-cache";
        Group = "nix-cache";
        SupplementaryGroups = ["systemd-journal"];
        LoadCredential = cfg.alerts.loadCredential;
      };
    };
  };
}
