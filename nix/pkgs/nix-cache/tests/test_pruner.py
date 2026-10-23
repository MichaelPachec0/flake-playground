import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pytest

from helpers import fake_hash, make_config, store_path
from nix_cache import nixcli, pruner
from nix_cache.alert import queue_alert
from nix_cache.db import open_db
from nix_cache.graph import store_hash
from nix_cache.pins import Namespace, latest_stamps, list_pins, pin

NS = Namespace("flake-playground", "gate", "x86_64-linux")
OLD_NS = Namespace("flake-playground", "bump-picr", "x86_64-linux")
DAY = 86400
NOW = 100 * DAY
A, B, C = store_path(1, "a"), store_path(2, "b"), store_path(3, "c")


def info(size=10, refs=(), reg=0):
    return {"narSize": size, "references": list(refs), "deriver": None, "registrationTime": reg}


@pytest.fixture
def env(tmp_path, monkeypatch):
    cfg = make_config(tmp_path)  # budget_bytes = 1000
    graph: dict = {store_path(90, "filler"): info(1)}  # non-empty: the pruner refuses an empty store
    monkeypatch.setattr(nixcli, "path_info", lambda paths=(), **kw: graph)
    return cfg, graph


def titles(cfg):
    return [json.loads(p.read_text())["title"] for p in sorted(cfg.spool.glob("*.json"))]


def test_applies_plan(env):
    cfg, graph = env
    graph.update({A: info(600), B: info(600)})
    pin(cfg.pins_dir, NS, [A], NOW - 2 * DAY)
    pin(cfg.pins_dir, NS, [B], NOW - DAY)
    summary = pruner.run(cfg, now=NOW)
    assert summary["delete_pins"] == [f"{NS}@{NOW - 2 * DAY}"]
    assert [p.targets for p in list_pins(cfg.pins_dir)] == [(B,)]
    keep = cfg.gcroots_dir / f"keep.{NOW}"
    assert [os.readlink(l) for l in keep.iterdir()] == [B]


def test_dry_run_changes_nothing(env):
    cfg, graph = env
    graph.update({A: info(600), B: info(600)})
    pin(cfg.pins_dir, NS, [A], NOW - 2 * DAY)
    pin(cfg.pins_dir, NS, [B], NOW - DAY)
    summary = pruner.run(cfg, now=NOW, dry_run=True)
    assert summary["dry_run"] and len(list_pins(cfg.pins_dir)) == 2
    assert not list(cfg.gcroots_dir.glob("keep.*"))


def test_keep_dir_is_replaced(env):
    cfg, graph = env
    graph.update({A: info()})
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    pruner.run(cfg, now=NOW)
    pruner.run(cfg, now=NOW + 1)
    assert [d.name for d in cfg.gcroots_dir.glob("keep.*")] == [f"keep.{NOW + 1}"]
    assert pruner.read_keep(cfg.gcroots_dir) == {A}


def test_overrides(env):
    cfg, graph = env
    graph.update({A: info(), B: info()})
    pin(cfg.pins_dir, NS, [A], NOW - 2 * DAY)
    pin(cfg.pins_dir, NS, [B], NOW - DAY)
    pruner.run(cfg, now=NOW, budget_bytes=1, active_days=0, protect_hours=0)
    assert list_pins(cfg.pins_dir) == [] and latest_stamps(cfg.pins_dir) == {}


def test_expired_alert_once(env):
    cfg, graph = env
    graph.update({A: info(), C: info()})
    pin(cfg.pins_dir, OLD_NS, [C], NOW - 40 * DAY)
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    pruner.run(cfg, now=NOW)
    pruner.run(cfg, now=NOW + 3600)
    assert titles(cfg).count("nix-cache: namespace expired") == 1


def test_over_budget_alert_daily(env):
    cfg, graph = env
    graph.update({A: info(5000)})
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    pruner.run(cfg, now=NOW)
    pruner.run(cfg, now=NOW + 60)
    pruner.run(cfg, now=NOW + DAY)
    assert titles(cfg).count("nix-cache: over budget") == 2


def test_stale_token_alert(env):
    cfg, graph = env
    ok = {"t": "2026-10-22T07:00:00+00:00", "u": "nyx-g1", "uri": "/nix-cache-info", "s": 200, "b": 1}
    bad = dict(ok, s=401)
    cfg.access_log.write_text(json.dumps(ok) + "\n" + (json.dumps(bad) + "\n") * 25)
    pruner.run(cfg, now=NOW)
    pruner.run(cfg, now=NOW + 60)
    assert titles(cfg).count("nix-cache: stale read token") == 1


def test_unknown_user_failures_do_not_alert(env):
    cfg, graph = env
    bad = {"t": "2026-10-22T07:00:00+00:00", "u": "nobody-g1", "uri": "/nix-cache-info", "s": 401, "b": 1}
    cfg.access_log.write_text((json.dumps(bad) + "\n") * 50)
    pruner.run(cfg, now=NOW)
    assert "nix-cache: stale read token" not in titles(cfg)


def test_key_expiry_alert(env):
    cfg, graph = env  # make_config sets upload_key_expiry ["20991231"]
    pruner.run(cfg, now=NOW)
    assert "nix-cache: upload key expiring" not in titles(cfg)
    soon = int(datetime(2099, 12, 20, tzinfo=timezone.utc).timestamp())
    pruner.run(cfg, now=soon)
    pruner.run(cfg, now=soon + 60)
    assert titles(cfg).count("nix-cache: upload key expiring") == 1


def test_requeues_deferred_alerts(env):
    cfg, _ = env
    queued = queue_alert(cfg.deferred, "t", "b")
    pruner.run(cfg, now=NOW)
    assert (cfg.spool / queued.name).exists()


def test_main_prints_summary(env, capsys, tmp_path):
    assert pruner.main(["--config", str(tmp_path / "config.json"), "--dry-run", "--now", str(NOW)]) == 0
    summary = json.loads(capsys.readouterr().out)
    assert sorted(summary) == ["budget_bytes", "delete_pins", "dry_run", "expired", "kept_bytes", "kept_paths", "over_budget", "roots"]


def _log(cfg, lines):
    cfg.access_log.write_text("".join(json.dumps(l) + "\n" for l in lines))


def test_stale_token_alert_rate_limited_per_user(env):
    cfg, _ = env
    ok = {"t": "2026-10-22T07:00:00+00:00", "u": "nyx-g1", "uri": "/nix-cache-info", "s": 200, "b": 1}
    bad = dict(ok, s=401)
    _log(cfg, [ok] + [bad] * 25)
    pruner.run(cfg, now=NOW)
    # An attacker guessing the user name inflates failures again within the hour.
    with open(cfg.access_log, "a") as f:
        f.write((json.dumps(bad) + "\n") * 25)
    pruner.run(cfg, now=NOW + 60)
    assert titles(cfg).count("nix-cache: stale read token") == 1
    pruner.run(cfg, now=NOW + 3601)
    assert titles(cfg).count("nix-cache: stale read token") == 2


def test_sweeps_orphaned_pin_temp_dirs(env):
    cfg, graph = env
    graph.update({A: info()})
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    base = NS.dir(cfg.pins_dir)
    for name in (f".{NOW}.tmp", f".{NOW}.del"):
        (base / name).mkdir()
        os.symlink(B, base / name / Path(B).name)
    pruner.run(cfg, now=NOW, dry_run=True)
    assert (base / f".{NOW}.tmp").exists()
    pruner.run(cfg, now=NOW)
    assert not (base / f".{NOW}.tmp").exists() and not (base / f".{NOW}.del").exists()
    assert [p.targets for p in list_pins(cfg.pins_dir)] == [(A,)]


def test_prunes_path_rows_not_in_store(env):
    cfg, graph = env
    graph.update({A: info()})
    live, junk = store_hash(A), fake_hash(99)
    ok = {"t": "2026-10-22T07:00:00+00:00", "u": "", "s": 200, "b": 1}
    _log(cfg, [dict(ok, uri=f"/{live}.narinfo"), dict(ok, uri=f"/{junk}.narinfo"),
               dict(ok, uri=f"/nar/x.nar.zst?hash={junk}")])
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    pruner.run(cfg, now=NOW)
    conn = open_db(cfg.db)
    assert [h for (h,) in conn.execute("SELECT hash FROM paths")] == [live]
    conn.close()


def test_orphaned_keep_tmp_is_removed(env):
    cfg, graph = env
    graph.update({A: info()})
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    orphan = cfg.gcroots_dir / ".keep.1.tmp"
    orphan.mkdir()
    os.symlink(B, orphan / Path(B).name)
    pruner.run(cfg, now=NOW, dry_run=True)
    assert orphan.exists()
    pruner.run(cfg, now=NOW)
    assert not orphan.exists()


def test_expired_alert_again_after_revival(env):
    cfg, graph = env
    graph.update({A: info(), C: info()})
    pin(cfg.pins_dir, OLD_NS, [C], NOW - 40 * DAY)
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    pruner.run(cfg, now=NOW)
    pin(cfg.pins_dir, OLD_NS, [C], NOW + 1)
    later = NOW + 60 * DAY
    pruner.run(cfg, now=later)
    bodies = [json.loads(p.read_text())["body"] for p in cfg.spool.glob("*.json")]
    assert sum(b.startswith(str(OLD_NS)) for b in bodies) == 2


def test_empty_graph_refuses_to_apply(env, capsys, tmp_path):
    cfg, graph = env
    graph.clear()
    pin(cfg.pins_dir, NS, [A], NOW - DAY)
    before = list_pins(cfg.pins_dir)
    assert pruner.main(["--config", str(tmp_path / "config.json"), "--now", str(NOW)]) == 1
    assert "refusing" in capsys.readouterr().err
    assert list_pins(cfg.pins_dir) == before
    assert not list(cfg.gcroots_dir.glob("keep.*"))
