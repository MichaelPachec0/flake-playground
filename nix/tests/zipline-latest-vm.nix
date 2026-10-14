# E2E: services.zipline-latest fresh installs.
#
# `pg`: default database.type = postgresql with a local server. Checks the unit
# comes up, the API answers, Drizzle migrations were recorded, and the setup +
# login flow works end to end.
# `pglite`: database.type = pglite. Same API checks, the embedded DB directory
# exists, and no PostgreSQL server is running.
{
  pkgs,
  self,
}: let
  secret = builtins.toFile "zipline-latest.env" ''
    CORE_SECRET=DMlouex3W0QLRbVwkUafNnNws5jpgRDX
  '';
  common = {lib, ...}: {
    imports = [self.nixosModules.zipline-latest];
    # Old CPU without SSE 4.2: proves sharp uses the system libvips.
    virtualisation.qemu.options = lib.mkIf pkgs.stdenv.hostPlatform.isx86 ["-cpu core2duo"];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    services.zipline-latest = {
      enable = true;
      settings.CORE_PORT = 8000;
      environmentFiles = [secret];
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "zipline-latest";
    nodes.pg = {imports = [common];};
    nodes.pglite = {
      imports = [common];
      services.zipline-latest.database.type = "pglite";
    };
    testScript = ''
      import json
      import re

      def setup_and_login(m):
          m.wait_for_unit("zipline-latest.service")
          m.wait_for_open_port(8000, timeout=300)
          m.succeed("curl -fs 127.0.0.1:8000/api/healthcheck")
          resp = m.succeed("curl -fs 127.0.0.1:8000/api/setup -X POST -H 'Content-Type: application/json' -d '{\"username\": \"administrator\", \"password\": \"password\"}'")
          assert json.loads(resp)["user"]["role"] == "SUPERADMIN"
          resp = m.succeed("curl -s 127.0.0.1:8000/api/auth/login -v -X POST -H 'Content-Type: application/json' -d '{\"username\": \"administrator\", \"password\": \"password\"}' 2>&1")
          assert re.search(r"(?m)^< set-cookie: ([^;]*)", resp)

      start_all()

      setup_and_login(pg)
      pg.succeed("[ \"$(sudo -u postgres psql -XAtq -d zipline-latest -c 'SELECT count(*) > 0 FROM drizzle.__drizzle_migrations')\" = t ]")

      setup_and_login(pglite)
      pglite.succeed("test -d /var/lib/zipline-latest/db")
      pglite.fail("systemctl is-active postgresql.service")
    '';
  }
