# E2E test: boot two VMs with services.pingvin-share-x.
#
# `machine`: declarative settings omitting `initUser` - the path that used
# to crash the backend (ConfigService.migrateInitUser reads
# yamlConfig.initUser.enabled with no guard for it being absent;
# compose-config.js now fills a safe `initUser.enabled = false` default).
# Checks: three units come up, backend health + frontend both answer,
# config.yaml composed with the declarative appName.
#
# `bare`: module's bare default (enable = true, no settings/secrets).
# Checks: hasConfig gating skips composing config.yaml (empty settings =
# pure UI mode), backend still comes up healthy instead of crash-looping.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "pingvin-share";
  nodes.machine = {...}: {
    imports = [self.nixosModules.pingvin-share];
    services.pingvin-share-x = {
      enable = true;
      settings = {
        general.appName = "CI Pingvin";
        general.appUrl = "http://localhost:3333";
        # No initUser on purpose: used to crash on every boot before the
        # compose-config.js fix (TypeError reading .enabled off undefined).
      };
    };
    # Room for DB migration + node boot
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };
  nodes.bare = {...}: {
    imports = [self.nixosModules.pingvin-share];
    services.pingvin-share-x.enable = true;
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };
  testScript = ''
    machine.start()
    bare.start()

    machine.wait_for_unit("pingvin-share-migrate.service")
    machine.wait_for_unit("pingvin-share-backend.service")
    machine.wait_for_unit("pingvin-share-frontend.service")
    machine.wait_for_open_port(8080)
    machine.wait_for_open_port(3333)
    # backend health
    machine.succeed("curl -fs http://127.0.0.1:8080/api/health")
    # frontend serves HTML
    machine.succeed("curl -fs http://127.0.0.1:3333/ | grep -qi '<!doctype html>' || curl -fs http://127.0.0.1:3333/")
    # config.yaml composed from settings; missing initUser filled safely
    # instead of crashing.
    machine.succeed("grep -q 'CI Pingvin' /var/lib/pingvin-share/config.yaml")
    machine.succeed("grep -q 'enabled: false' /var/lib/pingvin-share/config.yaml")

    # Bare default: module skips composing config.yaml (pure UI mode).
    # Backend must still come up healthy, not crash-loop on the same
    # yamlConfig.initUser read.
    bare.wait_for_unit("pingvin-share-migrate.service")
    bare.wait_for_unit("pingvin-share-backend.service")
    bare.wait_for_unit("pingvin-share-frontend.service")
    bare.wait_for_open_port(8080)
    bare.wait_for_open_port(3333)
    bare.succeed("curl -fs http://127.0.0.1:8080/api/health")
    bare.fail("test -e /var/lib/pingvin-share/config.yaml")
    # Confirm no restarts since start (not just "up" mid crash-loop).
    bare.succeed(
        "[ \"$(systemctl show pingvin-share-backend.service -p NRestarts --value)\" = 0 ]"
    )
  '';
}
