# Write path, store half: one path-activated importer per repo. It runs as
# the untrusted nix-cache user with no network; the nix-daemon (reached over
# its unix socket) re-checks every signature on import.
{
  config,
  lib,
  ...
}: let
  cfg = config.services.nix-cache-host;
  hardening = import ./hardening.nix;
in {
  config = lib.mkIf cfg.enable {
    systemd.paths = lib.mapAttrs' (repo: _:
      lib.nameValuePair "cache-importer-${repo}" {
        description = "Watch for nix-cache uploads from ${repo}";
        wantedBy = ["paths.target"];
        # Uploads land in tmp/ and are renamed into incoming/ when complete,
        # so a matching name in incoming/ is always a whole bundle. A glob,
        # not DirectoryNotEmpty: the importer leaves names it does not
        # recognise in incoming/, and a non-empty directory would re-trigger
        # the unit after every run until its start limit stops real uploads.
        pathConfig.PathExistsGlob = "/srv/cache-drop/${repo}/incoming/*.tar.zst";
      })
    cfg.repos;

    systemd.services = lib.mapAttrs' (repo: _:
      lib.nameValuePair "cache-importer-${repo}" {
        description = "Import nix-cache bundles uploaded by ${repo}";
        path = [config.nix.package];
        unitConfig.OnFailure = ["nix-cache-unit-failed@%n.service"];
        serviceConfig =
          hardening
          // {
            Type = "oneshot";
            User = "nix-cache";
            Group = "nix-cache";
            ExecStart = "${lib.getExe' cfg.package "cache-importer"} --config ${cfg.configFile} --repo ${repo}";
            ReadWritePaths = [
              "/srv/cache-drop/${repo}"
              "/nix/var/nix/gcroots/cache"
              "/var/lib/nix-cache"
            ];
            MemoryMax = "2G";
          };
      })
    cfg.repos;
  };
}
