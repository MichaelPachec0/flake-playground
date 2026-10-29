# E2E: in-place upgrades of a real nixpkgs 4.7.0 install to zipline-latest,
# on the same services.zipline unit and database, with zipline-extras.
#
# `gate`: 4.7.0 creates the DB and a file, then one Prisma migration row (the
# very first one) is deleted and the package is switched to zipline-latest.
# Upstream must refuse ("cannot safely migrate"), record no Drizzle history,
# and the zipline-extras pre-start must still have logged the adoption warning
# and written the pre-drizzle backup.
#
# `migration`: 4.7.0 -> zipline-latest in place (adoption, backup, file still
# served), then the adopted PostgreSQL database -> PGlite (migrateToPglite).
{
  pkgs,
  self,
  seedNixpkgs,
}: let
  lib = pkgs.lib;
  seedZipline = seedNixpkgs.zipline;
  seedChkFunc = seedPkg: let
    ver = seedPkg.version;
  in
    assert lib.assertMsg (ver == "4.7.0")
    "zipline-latest-migration-vm: zipline is ${ver}, not 4.7.0; migration test failed"; seedPkg;

  seed = seedChkFunc seedZipline;
  secret = builtins.toFile "zipline.env" ''
    CORE_SECRET=DMlouex3W0QLRbVwkUafNnNws5jpgRDX
  '';
  base = {
    imports = [self.nixosModules.zipline-extras];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 6144;
    services.zipline = {
      enable = true;
      package = seed;
      settings.CORE_PORT = 8000;
      environmentFiles = [secret];
    };
    services.zipline-extras.enable = true;
  };
  latest = {
    services.zipline.package = lib.mkForce self.packages.${pkgs.stdenv.hostPlatform.system}.zipline-latest;
  };
in
  pkgs.testers.runNixOSTest {
    name = "zipline-latest-migration";
    nodes.gate = {
      imports = [base];
      specialisation.upgrade.configuration = {imports = [latest];};
    };
    nodes.migration = {
      imports = [base];
      specialisation.upgrade.configuration = {imports = [latest];};
      specialisation.pglite.configuration = {
        imports = [latest];
        services.zipline.database.createLocally = false;
        services.zipline-extras.experimental.migrateToPglite.enable = true;
      };
    };
    testScript = ''
      import json
      import re

      # Every curl carries --max-time: without it a request the server never
      # answers blocks m.succeed forever and the run dies at the CI job
      # timeout with no hint of which step hung.
      def seed_47(m):
          m.wait_for_unit("zipline.service")
          m.wait_for_open_port(8000, timeout=300)
          m.succeed("curl --max-time 30 -fs 127.0.0.1:8000/api/setup -X POST -H 'Content-Type: application/json' -d '{\"username\": \"administrator\", \"password\": \"password\"}'")
          resp = m.succeed("curl --max-time 30 -s 127.0.0.1:8000/api/auth/login -v -X POST -H 'Content-Type: application/json' -d '{\"username\": \"administrator\", \"password\": \"password\"}' 2>&1")
          found = re.search(r"(?m)^< set-cookie: ([^;]*)", resp)
          assert found is not None, "no set-cookie in login response"
          cookie = found[1]
          token = json.loads(m.succeed(f"curl --max-time 30 -fs 127.0.0.1:8000/api/user/token -H 'Cookie: {cookie}'"))["token"]
          m.succeed("echo hello-zipline > /tmp/f.txt")
          up = json.loads(m.succeed(f"curl --max-time 30 -fs 127.0.0.1:8000/api/upload -H 'authorization: {token}' -F file=@/tmp/f.txt"))
          fname = up["files"][0]["url"].rstrip("/").split("/")[-1]
          m.succeed(f"curl --max-time 30 -fs 127.0.0.1:8000/raw/{fname} | grep -q hello-zipline")
          return fname

      def switch(m, spec):
          # booted-system keeps the specialisation/ dir; current-system does not.
          return m.execute(f"/run/booted-system/specialisation/{spec}/bin/switch-to-configuration test")

      def psql(m, db, sql):
          return m.succeed(f"sudo -u postgres psql -XAtq -d {db} -c \"{sql}\"").strip()

      start_all()

      # gate: corrupt a 4.7.0 history, upstream must refuse without side effects
      seed_47(gate)
      gate.succeed("systemctl stop zipline.service")
      psql(gate, "zipline", "DELETE FROM _prisma_migrations WHERE migration_name = '20241228224006_init'")
      switch(gate, "upgrade")
      gate.wait_until_fails("systemctl is-active zipline.service", timeout=300)
      gate.wait_until_succeeds("journalctl -u zipline -b --no-pager | grep -q 'cannot safely migrate'", timeout=120)
      gate.succeed("journalctl -u zipline -b --no-pager | grep -q 'will adopt a Zipline 4.7 database'")
      gate.succeed("ls /var/lib/private/zipline/backups/pre-drizzle-*.sql")
      assert psql(gate, "zipline", "SELECT to_regclass('drizzle.__drizzle_migrations') IS NULL") == "t"

      # migration: real 4.7.0 install -> zipline-latest in place (adoption)
      fname = seed_47(migration)
      switch(migration, "upgrade")
      migration.wait_until_succeeds("journalctl -u zipline -b --no-pager | grep -q 'will adopt a Zipline 4.7 database'", timeout=300)
      migration.wait_for_unit("zipline.service")
      migration.wait_for_open_port(8000, timeout=300)
      migration.wait_until_succeeds(f"curl --max-time 30 -fs 127.0.0.1:8000/raw/{fname} | grep -q hello-zipline", timeout=120)
      migration.succeed("ls /var/lib/private/zipline/backups/pre-drizzle-*.sql")
      assert psql(migration, "zipline", "SELECT count(*) > 0 FROM drizzle.__drizzle_migrations") == "t"

      # migration, step 2: adopted PostgreSQL -> PGlite cutover
      switch(migration, "pglite")
      migration.wait_for_unit("zipline.service")
      migration.wait_for_open_port(8000, timeout=300)
      migration.succeed("systemctl is-active zipline-pglite-cutover.service")
      migration.succeed("test -d /var/lib/private/zipline/db")
      migration.succeed("ls /var/lib/private/zipline/backups/pre-pglite-*.sql")
      migration.succeed("systemctl show zipline -p Environment --value | grep -q 'DATABASE_URL=pglite:///var/lib/zipline/db'")
      migration.wait_until_succeeds(f"curl --max-time 30 -fs 127.0.0.1:8000/raw/{fname} | grep -q hello-zipline", timeout=120)
    '';
  }
