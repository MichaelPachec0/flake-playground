# E2E: zipline-latest migration paths, seeded from a real nixpkgs 4.7.0 install.
#
# `gate`: nixpkgs services.zipline 4.7.0 creates the DB and a file, then one
# Prisma migration row (the very first one) is deleted. zipline-latest is
# pointed at that DB in place. Upstream must refuse ("cannot safely migrate"),
# record no Drizzle history, and our pre-start must still have logged the
# adoption warning and written the pre-drizzle backup.
{
  pkgs,
  self,
}: let
  lib = pkgs.lib;
  # The seed must be a real 4.7.0 install. When nixpkgs moves past 4.7.0, pin
  # it: pkgs.zipline.overrideAttrs to tag v4.7.0 with src hash
  # sha256-/ISegKJ6NyyLYMoovqWLzJCP9JKsPW76Lm6hTU4NTmU= and pnpmDeps hash
  # sha256-y6BZ7A/4jSMA2sSByDx3czwlc9WM6QUCcguLouNQouk=.
  seed = assert lib.assertMsg (pkgs.zipline.version == "4.7.0")
  "zipline-latest-migration-vm: nixpkgs zipline is ${pkgs.zipline.version}, not 4.7.0; pin the seed (see comment)";
    pkgs.zipline;
  secret = builtins.toFile "zipline.env" ''
    CORE_SECRET=DMlouex3W0QLRbVwkUafNnNws5jpgRDX
  '';
  base = {lib, ...}: {
    imports = [self.nixosModules.zipline-latest];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 6144;
    services.zipline = {
      enable = true;
      package = seed;
      settings.CORE_PORT = 8000;
      environmentFiles = [secret];
    };
  };
  latest = {
    services.zipline.enable = lib.mkForce false;
    services.zipline-latest = {
      enable = true;
      settings.CORE_PORT = 8000;
      environmentFiles = [secret];
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "zipline-latest-migration";
    nodes.gate = {
      imports = [base];
      specialisation.inplace.configuration = {
        imports = [latest];
        # Same DB as nixpkgs zipline, in place (no import). Disabling
        # services.zipline also drops the PostgreSQL server it enabled, so keep
        # it on explicitly.
        services.postgresql.enable = true;
        services.zipline-latest.database.createLocally = false;
        services.zipline-latest.settings.DATABASE_URL = "postgresql://zipline@localhost/zipline?host=/run/postgresql";
        # Peer auth maps the OS user to the role: run as `zipline` here.
        systemd.services.zipline-latest.serviceConfig.User = lib.mkForce "zipline";
        systemd.services.zipline-latest.serviceConfig.Group = lib.mkForce "zipline";
        systemd.services.zipline-latest.after = ["postgresql.target"];
        systemd.services.zipline-latest.requires = ["postgresql.target"];
      };
      specialisation.import.configuration = {
        imports = [latest];
        services.zipline-latest.experimental.importFromNixpkgs.enable = true;
      };
    };
    nodes.migration = {
      imports = [base];
      specialisation.import.configuration = {
        imports = [latest];
        services.zipline-latest.experimental.importFromNixpkgs.enable = true;
      };
      specialisation.pglite.configuration = {
        imports = [latest];
        services.zipline-latest.database.type = "pglite";
        services.zipline-latest.experimental.migrateToPglite.enable = true;
      };
    };
    testScript = ''
      import json
      import re

      def seed_47(m):
          m.wait_for_unit("zipline.service")
          m.wait_for_open_port(8000, timeout=300)
          m.succeed("curl -fs 127.0.0.1:8000/api/setup -X POST -H 'Content-Type: application/json' -d '{\"username\": \"administrator\", \"password\": \"password\"}'")
          resp = m.succeed("curl -s 127.0.0.1:8000/api/auth/login -v -X POST -H 'Content-Type: application/json' -d '{\"username\": \"administrator\", \"password\": \"password\"}' 2>&1")
          found = re.search(r"(?m)^< set-cookie: ([^;]*)", resp)
          assert found is not None, "no set-cookie in login response"
          cookie = found[1]
          token = json.loads(m.succeed(f"curl -fs 127.0.0.1:8000/api/user/token -H 'Cookie: {cookie}'"))["token"]
          m.succeed("echo hello-zipline > /tmp/f.txt")
          up = json.loads(m.succeed(f"curl -fs 127.0.0.1:8000/api/upload -H 'authorization: {token}' -F file=@/tmp/f.txt"))
          fname = up["files"][0]["url"].rstrip("/").split("/")[-1]
          m.succeed(f"curl -fs 127.0.0.1:8000/raw/{fname} | grep -q hello-zipline")
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
      switch(gate, "inplace")
      gate.wait_until_fails("systemctl is-active zipline-latest.service", timeout=300)
      gate.wait_until_succeeds("journalctl -u zipline-latest -b --no-pager | grep -q 'cannot safely migrate'", timeout=120)
      gate.succeed("journalctl -u zipline-latest -b --no-pager | grep -q 'will adopt a Zipline 4.7 database'")
      gate.succeed("ls /var/lib/private/zipline-latest/backups/pre-drizzle-*.sql")
      assert psql(gate, "zipline", "SELECT to_regclass('drizzle.__drizzle_migrations') IS NULL") == "t"

      # migration: real 4.7.0 install -> import -> 4.8 adoption
      fname = seed_47(migration)
      switch(migration, "import")
      migration.wait_for_unit("zipline-latest.service")
      migration.wait_for_open_port(8000, timeout=300)
      migration.succeed("systemctl is-active zipline-latest-import.service")
      migration.succeed(f"curl -fs 127.0.0.1:8000/raw/{fname} | grep -q hello-zipline")
      migration.succeed("ls /var/lib/private/zipline-latest/backups/import-*.dump")
      migration.succeed("ls /var/lib/private/zipline-latest/backups/pre-drizzle-*.sql")
      migration.succeed("test -e /var/lib/private/zipline-latest/.imported-from-nixpkgs")
      assert psql(migration, "zipline-latest", "SELECT count(*) > 0 FROM drizzle.__drizzle_migrations") == "t"
      # source left untouched (rollback path): still Prisma-only
      assert psql(migration, "zipline", "SELECT to_regclass('drizzle.__drizzle_migrations') IS NULL") == "t"

      # migration, step 2: adopted PostgreSQL -> PGlite cutover
      switch(migration, "pglite")
      migration.wait_for_unit("zipline-latest.service")
      migration.wait_for_open_port(8000, timeout=300)
      migration.succeed("systemctl is-active zipline-latest-pglite-cutover.service")
      migration.succeed("test -d /var/lib/private/zipline-latest/db")
      migration.succeed("ls /var/lib/private/zipline-latest/backups/pre-pglite-*.sql")
      migration.succeed("systemctl show zipline-latest -p Environment --value | grep -q 'DATABASE_URL=pglite:///var/lib/zipline-latest/db'")
      migration.succeed(f"curl -fs 127.0.0.1:8000/raw/{fname} | grep -q hello-zipline")

      # gate, second half: re-run the import against a now non-empty target
      switch(gate, "import")
      gate.wait_until_fails("systemctl is-active zipline-latest.service", timeout=300)
      gate.succeed("rm -f /var/lib/private/zipline-latest/.imported-from-nixpkgs")
      gate.fail("systemctl restart zipline-latest-import.service")
      gate.succeed("journalctl -u zipline-latest-import -b --no-pager | grep -q 'is not empty'")
    '';
  }
