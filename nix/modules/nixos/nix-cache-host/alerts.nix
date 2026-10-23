# Alert delivery. Sandboxed units queue JSON files in /var/lib/nix-cache/alerts;
# this unit (network allowed) runs the configured command for each. Failed
# deliveries wait in alerts-deferred/ until the next pruner run requeues them.
{
  config,
  lib,
  utils,
  ...
}: let
  cfg = config.services.nix-cache-host;
  # The option type already rules out whitespace, quotes and %; escape anyway
  # so each context stays correct on its own.
  command = cfg.alerts.command;
in {
  config = lib.mkIf cfg.enable {
    systemd.paths.nix-cache-alert = {
      wantedBy = ["paths.target"];
      # A glob, not DirectoryNotEmpty: nix-cache-alert only consumes *.json,
      # so any other file left in the spool would re-trigger the unit until
      # its start limit trips and every later alert goes undelivered.
      pathConfig.PathExistsGlob = "/var/lib/nix-cache/alerts/*.json";
    };

    systemd.services.nix-cache-alert = {
      description = "Deliver queued nix-cache alerts";
      # Every queued alert can start this unit once, and a pruner pass or a
      # run of rejected uploads queues several within seconds. With systemd's
      # default start limit (5 per 10 s) the sixth start fails, and the path
      # unit then stays failed: every later alert would go undelivered. A
      # healthy run consumes or defers every *.json and so never re-triggers
      # itself; the generous limit only stops a crashing run from spinning.
      startLimitBurst = 100;
      startLimitIntervalSec = 60;
      serviceConfig = {
        Type = "oneshot";
        User = "nix-cache";
        Group = "nix-cache";
        LoadCredential = cfg.alerts.loadCredential;
        ExecStart = "${lib.getExe' cfg.package "nix-cache-alert"} --spool /var/lib/nix-cache/alerts --deferred /var/lib/nix-cache/alerts-deferred --command ${utils.escapeSystemdExecArg command}";
      };
    };

    systemd.services."nix-cache-unit-failed@" = {
      description = "Alert that %i failed";
      scriptArgs = "%i";
      script = ''
        ${config.systemd.package}/bin/journalctl -u "$1" -n 40 --no-pager | ${lib.escapeShellArg command} "nix-cache: $1 failed"
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
