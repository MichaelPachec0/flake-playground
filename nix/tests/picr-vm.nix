# On-demand integration test: boot PICR with managed Postgres, verify the HTTP
# server comes up, migrations ran, and the built frontend is served. This is the
# first real runtime exercise of services.picr; the eval checks only prove the
# module evaluates. Heavy (boots a VM), so it is wired as
# checks.x86_64-linux.picr-vm but kept OUT of the `default` aggregate.
#
# Two spec verify-items are settled here (spec section 11):
#   1. node-postgres/drizzle honoring the peer-auth socket DATABASE_URL
#      (postgresql://picr@localhost/picr?host=/run/postgresql). If picr cannot
#      reach the DB, picr.service never reaches active and wait_for_unit fails.
#   2. The ExecStartPre symlink shim + WorkingDirectory = stateDir giving the app
#      its cwd-relative backend/db/drizzle (migrations) and writable cache/. A
#      broken cwd shim shows up as a migration failure or a dead server.
{
  pkgs,
  nixosModules,
}:
# pkgs.testers.nixosTest is the current entrypoint (the bare pkgs.nixosTest
# alias was removed in nixpkgs 2025-10).
pkgs.testers.nixosTest {
  name = "picr";
  nodes.machine = {...}: {
    imports = [nixosModules.picr];
    services.picr.enable = true;
    services.picr.baseUrl = "http://localhost:6900/";
    # Managed Postgres over the peer-auth socket is the default; leave it on so
    # this test settles verify-item #1 above.
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };
  testScript = ''
    start_all()

    # Postgres must be up before picr, which runs migrations in-process at boot.
    machine.wait_for_unit("postgresql.service")

    # If the socket DATABASE_URL is rejected, or the cwd shim hides the
    # migrations dir, picr.service dies here instead of reaching active.
    machine.wait_for_unit("picr.service")
    machine.wait_for_open_port(6900)

    # Built frontend (dist/public) is served at the site root.
    machine.succeed("curl -fsS http://localhost:6900/ | grep -qi '<!doctype html'")

    # Migrations ran cleanly: no drizzle/migration failure line in the journal.
    # (A failure would already have killed the unit above; this catches a
    # degraded-but-alive server that logged a migration error.)
    machine.fail(
        "journalctl -u picr.service --no-pager | grep -qiE 'migration.*(fail|error)'"
    )

    # The unit is genuinely active (not merely activating/restart-looping).
    machine.succeed("systemctl is-active picr.service")
  '';
}
