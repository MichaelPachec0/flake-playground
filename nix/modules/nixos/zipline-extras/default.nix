# Add-on helpers for nixpkgs services.zipline (4.8.0+). It does not replace
# that module: it only adds an ExecStartPre to systemd.services.zipline and an
# optional one-shot unit. Inert unless services.zipline-extras.enable.
#
# Running the latest upstream release instead of the nixpkgs one:
#   services.zipline.package = pkgs.zipline-latest;  # overlays.zipline-latest
#
# PGlite on a fresh install needs no helper:
#   services.zipline.database.createLocally = false;
#   services.zipline.settings.DATABASE_URL = "pglite:///var/lib/zipline/db";
#
# Upgrading a 4.7.0 PostgreSQL database to 4.8.0+: upstream refuses on its own
# unless EXACTLY the 4.7.0 Prisma migration set is applied (checked with
# checksums inside one transaction; on mismatch it rolls back, records nothing
# and the unit fails with "cannot safely migrate from prisma to drizzle").
# Before that, the pre-start check here logs the follow-up steps and, with
# backupBeforeAdoption, pg_dumps to /var/lib/zipline/backups. A `?schema=`
# parameter in DATABASE_URL is stripped for that pre-check (libpq rejects it;
# upstream's driver ignores it).
#
# Follow-up steps after 4.8.0 that cannot be inferred:
#   * behind a reverse proxy, set settings.CORE_TRUSTED_PROXIES
#     (CORE_TRUST_PROXY alone is ignored since 4.8.0);
#   * custom uploaders must switch partialIdentifier / x-zipline-p-identifier
#     to partialToken / x-zipline-p-token;
#   * keep the same CORE_SECRET: API tokens handed to uploaders are encrypted
#     with it.
#
# experimental.migrateToPglite automates upstream's `ziplinectl migrate-pglite`
# cutover. Roll back by pointing DATABASE_URL at PostgreSQL again (and
# createLocally = true); writes made on PGlite are not copied back. To cut over
# again later, move /var/lib/private/zipline/db aside first, otherwise the
# stale PGlite is used.
_inputs: {
  config,
  lib,
  pkgs,
  ...
}: let
  zcfg = config.services.zipline;
  cfg = config.services.zipline-extras;
  cut = cfg.experimental.migrateToPglite;
  name = "zipline";
  # What the app sees (systemd symlink) vs. the real path behind DynamicUser.
  stateDir = "/var/lib/${name}";
  privateDir = "/var/lib/private/${name}";
  pgliteUrl = "pglite://${stateDir}/db";
  localPgUrl = "postgresql://${name}@localhost/${name}?host=/run/postgresql";
  # services.postgresql.package has no value while the server is disabled
  # (an external database); psql/pg_dump still run.
  pgPackage =
    if config.services.postgresql.enable
    then config.services.postgresql.package
    else pkgs.postgresql;
  isPglite = lib.hasPrefix "pglite:" (zcfg.settings.DATABASE_URL or "");

  # Runs as the service user before every start (postgresql only). Detects the
  # one start that will adopt a 4.7.0 Prisma database (Prisma history present,
  # Drizzle history absent), logs the follow-up steps and optionally pg_dumps.
  # It never judges the Prisma history itself: upstream does that right after,
  # transactionally, against its own checksum list.
  adoptionCheck = pkgs.writeShellApplication {
    name = "${name}-adoption-check";
    runtimeInputs = [pgPackage pkgs.coreutils pkgs.gnused];
    text = ''
      if [ -z "''${DATABASE_URL:-}" ]; then
        echo "<4>${name}: DATABASE_URL unset (DATABASE_* variables?); skipping the adoption pre-check"
        exit 0
      fi
      case "$DATABASE_URL" in pglite:*) exit 0 ;; esac

      # libpq rejects the `schema` query parameter that upstream's 4.7 README
      # documents (node-postgres ignores it): strip only that one for psql and pg_dump.
      pg_url=$(printf '%s' "$DATABASE_URL" | sed -E -e 's/([?&])schema=[^&]*&/\1/' -e 's/[?&]schema=[^&]*$//')

      q() { psql "$pg_url" -XAtq -c "$1"; }

      # Capture first: a failing psql inside a bare `[ "$(...)" ]` test would not
      # trip errexit and would read as "no Prisma history", failing open.
      prisma=$(q "SELECT to_regclass('public._prisma_migrations') IS NOT NULL")
      [ "$prisma" = t ] || exit 0
      drizzle_table=$(q "SELECT to_regclass('drizzle.__drizzle_migrations') IS NOT NULL")
      if [ "$drizzle_table" = t ]; then
        drizzle_rows=$(q 'SELECT count(*) > 0 FROM drizzle.__drizzle_migrations')
        [ "$drizzle_rows" = t ] && exit 0
      fi

      while IFS= read -r line; do echo "<4>$line"; done <<'EOF'
      ${name}: this start will adopt a Zipline 4.7 database (Prisma -> Drizzle).
      Upstream refuses unless the database is exactly on 4.7.0; nothing is changed if it refuses.
      Follow-up steps after 4.8.0:
        - back up the database first (automatic when services.zipline-extras.backupBeforeAdoption is on)
        - behind a reverse proxy: set services.zipline.settings.CORE_TRUSTED_PROXIES (CORE_TRUST_PROXY alone is ignored)
        - custom uploaders: partialIdentifier / x-zipline-p-identifier -> partialToken / x-zipline-p-token
        - keep the same CORE_SECRET as before
      Release notes: https://github.com/diced/zipline/releases/tag/v4.8.0
      EOF

      ${lib.optionalString cfg.backupBeforeAdoption ''
        install -d -m 0700 "$STATE_DIRECTORY/backups"
        out="$STATE_DIRECTORY/backups/pre-drizzle-$(date -u +%Y%m%dT%H%M%SZ).sql"
        # Dump to .partial and rename: a pg_dump killed by the start timeout must not look like a complete backup.
        pg_dump "$pg_url" --file="$out.partial"
        mv "$out.partial" "$out"
        echo "<5>${name}: backup written to $out"
      ''}
    '';
  };

  # Runs as the service's dynamic user (same name -> same UID), so the PGlite
  # files it creates are owned by the server. Upstream removes the target
  # directory on failure, so its existence is the done-marker.
  cutoverScript = pkgs.writeShellApplication {
    name = "${name}-pglite-cutover";
    runtimeInputs = [pgPackage pkgs.coreutils pkgs.gnused zcfg.package];
    text = ''
      src=${lib.escapeShellArg cut.sourceDatabaseUrl}
      fail() { echo "<3>${name}-pglite-cutover: $1" >&2; exit 1; }

      # libpq rejects the Prisma-only `schema` query parameter; strip it for
      # psql and pg_dump. ziplinectl (node-postgres) gets the original URL.
      pg_url=$(printf '%s' "$src" | sed -E -e 's/([?&])schema=[^&]*&/\1/' -e 's/[?&]schema=[^&]*$//')
      q() { psql "$pg_url" -XAtq -c "$1"; }

      # Capture first: a failing psql inside a bare `[ "$(...)" ]` test would
      # not trip errexit and would read as "not adopted", failing open.
      reg=$(q "SELECT to_regclass('drizzle.__drizzle_migrations') IS NOT NULL")
      [ "$reg" = t ] || fail "source is not adopted by 4.8 yet; start ${name} on postgresql once before cutover"
      rows=$(q 'SELECT count(*) > 0 FROM drizzle.__drizzle_migrations')
      [ "$rows" = t ] || fail "source is not adopted by 4.8 yet; start ${name} on postgresql once before cutover"

      install -d -m 0700 "$STATE_DIRECTORY/backups"
      out="$STATE_DIRECTORY/backups/pre-pglite-$(date -u +%Y%m%dT%H%M%SZ).sql"
      # Dump to .partial and rename: a pg_dump killed by the start timeout must not look like a complete backup.
      pg_dump "$pg_url" --file="$out.partial"
      mv "$out.partial" "$out"
      echo "<5>${name}-pglite-cutover: backup written to $out"

      # Build in a scratch dir and rename: upstream's cleanup only runs on a thrown
      # error, so a killed run would leave a schema-valid but empty db/ that
      # counts as done. Only a complete copy ever appears at db/.
      rm -rf "$STATE_DIRECTORY/db.cutover"
      ziplinectl migrate-pglite "$STATE_DIRECTORY/db.cutover" --source "$src"
      mv "$STATE_DIRECTORY/db.cutover" "$STATE_DIRECTORY/db"
      echo "<4>${name}-pglite-cutover: done. PostgreSQL database left in place for rollback; writes on PGlite are not copied back."
    '';
  };
in {
  options.services.zipline-extras = {
    enable = lib.mkEnableOption ''
      migration helpers for nixpkgs services.zipline: a pre-start check and
      backup before 4.8.0+ adopts a 4.7.0 database, and an optional
      PostgreSQL -> PGlite cutover
    '';

    backupBeforeAdoption = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        pg_dump to /var/lib/zipline/backups/pre-drizzle-<ts>.sql before the
        first start adopts a 4.7.0 Prisma database. A dump failure fails the
        unit. The pre-check needs DATABASE_URL (settings or environmentFiles);
        with only DATABASE_USERNAME/DATABASE_HOST/... variables it is skipped
        (a warning is logged) and no backup is taken. With an external
        database (local server disabled) pg_dump comes from pkgs.postgresql
        and refuses a newer server major version; set
        backupBeforeAdoption = false and back up by hand in that case.
      '';
    };

    experimental.migrateToPglite = {
      enable = lib.mkEnableOption ''
        a one-shot PostgreSQL -> PGlite cutover with upstream
        `ziplinectl migrate-pglite`, before the first PGlite start. Sets
        services.zipline.settings.DATABASE_URL to ${pgliteUrl} and keeps the
        local PostgreSQL server enabled when the source is the default local
        URL. EXPERIMENTAL
      '';
      sourceDatabaseUrl = lib.mkOption {
        type = lib.types.str;
        default = localPgUrl;
        description = ''
          PostgreSQL source; must already be adopted by 4.8.0+. The value is
          world-readable in the Nix store and visible in `ps` (passed as
          --source): use a password-less socket URL (peer auth) such as the
          default.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = zcfg.enable;
          message = "services.zipline-extras requires services.zipline.enable = true.";
        }
      ];

      warnings =
        lib.optional ((zcfg.settings ? CORE_TRUST_PROXY) && !(zcfg.settings ? CORE_TRUSTED_PROXIES))
        "services.zipline-extras: services.zipline.settings.CORE_TRUST_PROXY is set without CORE_TRUSTED_PROXIES; since 4.8.0 forwarded headers are then ignored, so all clients behind the proxy share rate limits.";

      systemd.services.${name}.serviceConfig.ExecStartPre = lib.optional (!isPglite) (lib.getExe adoptionCheck);
    }

    (lib.mkIf cut.enable {
      assertions = [
        {
          assertion = !zcfg.database.createLocally;
          message = "services.zipline-extras: experimental.migrateToPglite requires services.zipline.database.createLocally = false (the local PostgreSQL server stays enabled when the source is the default local URL).";
        }
        {
          assertion = (zcfg.settings.DATABASE_URL or "") == pgliteUrl;
          message = "services.zipline-extras: experimental.migrateToPglite writes to ${stateDir}/db; services.zipline.settings.DATABASE_URL must be \"${pgliteUrl}\".";
        }
      ];

      warnings = [
        "services.zipline-extras: experimental.migrateToPglite is EXPERIMENTAL; read the module header before relying on it. Writes made on PGlite are never copied back to PostgreSQL. To cut over again later, move ${privateDir}/db aside first, otherwise the stale PGlite is used."
      ];

      services.zipline.settings.DATABASE_URL = lib.mkDefault pgliteUrl;
      services.postgresql.enable = lib.mkIf (cut.sourceDatabaseUrl == localPgUrl) (lib.mkDefault true);

      systemd.services."${name}-pglite-cutover" = {
        description = "Zipline: one-shot PostgreSQL -> PGlite cutover";
        after = ["postgresql.target"];
        wants = ["postgresql.target"];
        before = ["${name}.service"];
        requiredBy = ["${name}.service"];
        unitConfig.ConditionPathExists = "!${privateDir}/db";
        environment = lib.mapAttrs (_: toString) zcfg.settings;
        # Same user, DynamicUser, StateDirectory, EnvironmentFile and hardening
        # as the main unit, so the two cannot drift apart.
        serviceConfig =
          lib.filterAttrs (n: _: !lib.hasPrefix "Exec" n) config.systemd.services.${name}.serviceConfig
          // {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe cutoverScript;
          };
      };
    })
  ]);
}
