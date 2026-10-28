"""cache-pruner: the hourly retention pass.

Ingests access stats, plans the keep set (retention.py), roots it under
gcroots/cache/keep.<now>/, deletes pins that are no longer needed and
queues notices. It never deletes store paths itself: cache-gc.service runs
`nix-store --gc` afterwards under the same lock.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from . import nixcli
from .accesslog import ingest
from .alert import queue_alert, requeue
from .config import Config, load_config
from .db import load_hits, mark_notice, notice_seen, open_db, prune_paths
from .graph import build_graph, store_hash, system_closure
from .lock import locked
from .pins import delete_pin, latest_stamps, list_pins, sweep_all
from .retention import Policy, RetentionPlan, plan_retention

STALE_THRESHOLD = 20
STALE_REALERT_SECONDS = 3600
EXPIRY_WARN_SECONDS = 14 * 86400
STORE_FS = "/nix/store"


class PrunerError(Exception):
    pass


def read_keep(gcroots_dir: Path) -> set[str]:
    result: set[str] = set()
    for d in gcroots_dir.glob("keep.*"):
        if d.is_dir() and not d.is_symlink():
            result.update(os.readlink(l) for l in d.iterdir() if l.is_symlink())
    return result


def write_keep(gcroots_dir: Path, tops, now: int) -> Path:
    gcroots_dir.mkdir(parents=True, exist_ok=True)
    # Orphans of a crashed earlier run are live GC roots; safe to drop under the lock.
    for orphan in gcroots_dir.glob(".keep.*.tmp"):
        shutil.rmtree(orphan, ignore_errors=True)
    tmp = gcroots_dir / f".keep.{now}.tmp"
    tmp.mkdir()
    for p in sorted(tops):
        os.symlink(p, tmp / Path(p).name)
    final = gcroots_dir / f"keep.{now}"
    if final.exists():
        shutil.rmtree(final)
    os.rename(tmp, final)
    for old in gcroots_dir.glob("keep.*"):
        if old != final and old.is_dir():
            shutil.rmtree(old)
    return final


def _once(conn: sqlite3.Connection, cfg: Config, key: str, now: int, title: str, body: str) -> None:
    if not notice_seen(conn, key):
        queue_alert(cfg.spool, title, body)
        mark_notice(conn, key, now)


def disk_notice(conn: sqlite3.Connection, cfg: Config, now: int) -> None:
    # Protected paths and failed/ bundles are not bounded by the budget, and
    # other users share the disk: warn before the importer's floor bites.
    try:
        st = os.statvfs(STORE_FS)
    except OSError as e:
        # Never let this abort the remaining notices.
        _once(conn, cfg, f"disk-check:{now // 86400}", now, "nix-cache: disk check failed",
              f"statvfs({STORE_FS}) failed: {e}. Disk usage is not being watched.")
        return
    if st.f_blocks == 0:
        return
    used_pct = 100 * (1 - st.f_bavail / st.f_blocks)
    if used_pct >= cfg.disk_alert_percent:
        _once(conn, cfg, f"disk:{now // 86400}", now, "nix-cache: disk filling",
              f"{STORE_FS} is {used_pct:.0f}% full (alert at {cfg.disk_alert_percent}%)."
              " Check the pruner's over-budget notices, failed/ bundles, and other users of the disk.")


def emit_notices(conn: sqlite3.Connection, cfg: Config, plan: RetentionPlan, now: int) -> None:
    newest: dict = {}
    for p in list_pins(cfg.pins_dir):
        newest[p.namespace] = max(newest.get(p.namespace, 0), p.stamp)
    for ns in plan.expired:
        # Keyed by the newest stamp so a namespace that revives and expires again alerts again.
        _once(conn, cfg, f"expired:{ns}:{newest.get(ns, 0)}", now, "nix-cache: namespace expired",
              f"{ns} has had no new pin for {cfg.active_days} days; its pins are now ordinary eviction candidates.")
    if plan.over_budget:
        _once(conn, cfg, f"over-budget:{now // 86400}", now, "nix-cache: over budget",
              f"Protected paths alone use {plan.kept_bytes} bytes against a budget of {cfg.budget_bytes};"
              " nothing else is kept. Raise the budget or retire namespaces.")
    for repo in cfg.repos.values():
        for day in repo.upload_key_expiry:
            expires = int(datetime.strptime(day, "%Y%m%d").replace(tzinfo=timezone.utc).timestamp())
            if now >= expires - EXPIRY_WARN_SECONDS:
                _once(conn, cfg, f"key-expiry:{repo.name}:{day}", now, "nix-cache: upload key expiring",
                      f"The {repo.name} upload key expires on {day}. Rotate it: generate a new key, add it"
                      " next to the old one, update the GitHub secret, confirm a push, remove the old key.")
    disk_notice(conn, cfg, now)
    rows = conn.execute(
        "SELECT name, recent_fails FROM users WHERE last_ok IS NOT NULL AND recent_fails >= ? "
        "AND (last_alert IS NULL OR last_alert <= ?)",
        (STALE_THRESHOLD, now - STALE_REALERT_SECONDS),
    ).fetchall()
    for name, fails in rows:
        queue_alert(cfg.spool, "nix-cache: stale read token",
                    f"{name}: {fails} rejected requests since its last success. The host is probably on a"
                    " retired token generation; update its netrc.")
        conn.execute("UPDATE users SET last_alert = ?, recent_fails = 0 WHERE name = ?", (now, name))
    conn.commit()


def run(
    cfg: Config,
    *,
    dry_run: bool = False,
    now: int | None = None,
    budget_bytes: int | None = None,
    protect_hours: int | None = None,
    active_days: int | None = None,
) -> dict:
    now = now if now is not None else int(time.time())
    policy = Policy.from_config(
        cfg, budget_bytes=budget_bytes, active_days=active_days, protect_hours=protect_hours
    )
    with locked(cfg.lock_file):
        requeue(cfg.deferred, cfg.spool)
        conn = open_db(cfg.db)
        try:
            ingest(conn, cfg.access_log)
            graph = build_graph(nixcli.path_info(all_paths=True))
            if not graph:
                raise PrunerError("nix path-info --all returned no store paths; refusing to apply")
            if not dry_run:
                sweep_all(cfg.pins_dir)
                prune_paths(conn, {store_hash(p) for p in graph})
            plan = plan_retention(
                graph=graph,
                pins=list_pins(cfg.pins_dir),
                latest=latest_stamps(cfg.pins_dir),
                previous_keep=read_keep(cfg.gcroots_dir),
                hits=load_hits(conn),
                system_paths=system_closure(graph, cfg.system_roots),
                policy=policy,
                now=now,
            )
            if not dry_run:
                write_keep(cfg.gcroots_dir, plan.tops, now)
                # Notices read the pins before they are deleted (expiry key uses the newest stamp).
                emit_notices(conn, cfg, plan, now)
                for p in plan.delete_pins:
                    delete_pin(cfg.pins_dir, p)
        finally:
            conn.close()
    return {
        "budget_bytes": policy.budget_bytes,
        "delete_pins": [f"{p.namespace}@{p.stamp}" for p in plan.delete_pins],
        "dry_run": dry_run,
        "expired": [str(ns) for ns in plan.expired],
        "kept_bytes": plan.kept_bytes,
        "kept_paths": len(plan.keep),
        "over_budget": plan.over_budget,
        "roots": len(plan.tops),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cache-pruner", description="Plan and apply nix-cache retention.")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true", help="change no roots, pins or notices (still requeues alerts and ingests the log)")
    parser.add_argument("--budget-bytes", type=int)
    parser.add_argument("--protect-hours", type=int)
    parser.add_argument("--active-days", type=int)
    parser.add_argument("--now", type=int, help="pretend the current epoch is NOW (tests)")
    args = parser.parse_args(argv)
    try:
        summary = run(
            load_config(args.config),
            dry_run=args.dry_run,
            now=args.now,
            budget_bytes=args.budget_bytes,
            protect_hours=args.protect_hours,
            active_days=args.active_days,
        )
    except PrunerError as e:
        print(f"cache-pruner: {e}", file=sys.stderr)
        return 1
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
