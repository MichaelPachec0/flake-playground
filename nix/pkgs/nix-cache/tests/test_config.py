from pathlib import Path

import json

import pytest
from helpers import make_config, write_config

from nix_cache.config import load_config


def test_load_config(tmp_path):
    cfg = make_config(tmp_path)
    repo = cfg.repos["flake-playground"]
    assert repo.incoming == repo.drop_dir / "incoming"
    assert repo.failed == repo.drop_dir / "failed"
    assert repo.trusted_keys[0].startswith("vmtest-repo-1:")
    assert cfg.pins_dir == Path(cfg.gcroots_dir) / "pins"
    assert cfg.lock_file == cfg.state_dir / "lock"
    assert cfg.spool == cfg.state_dir / "alerts"
    assert cfg.deferred == cfg.state_dir / "alerts-deferred"
    assert cfg.db == cfg.state_dir / "stats.sqlite"
    assert cfg.work_dir == cfg.state_dir / "work"
    assert repo.allowed_sets == ("gate", "many")
    assert repo.max_roots == 8


def _with_keys(tmp_path, keys):
    files = write_config(tmp_path)
    data = json.loads(files["config"].read_text())
    data["repos"]["flake-playground"]["trusted_keys"] = keys
    files["config"].write_text(json.dumps(data))
    return files["config"]


@pytest.mark.parametrize("keys", [[], ["a-1:AAA BBB"], ["a-1:AAA", "b:C C"], ["nocolon"], ["a:b\n"], [5]])
def test_bad_trusted_keys_rejected(tmp_path, keys):
    with pytest.raises(ValueError, match="trusted"):
        load_config(_with_keys(tmp_path, keys))


def _with_repo(tmp_path, **fields):
    files = write_config(tmp_path)
    data = json.loads(files["config"].read_text())
    data["repos"]["flake-playground"].update(fields)
    files["config"].write_text(json.dumps(data))
    return files["config"]


@pytest.mark.parametrize("sets", [[], "gate", ["gate", ""], ["Gate"], ["-gate"], ["gate\n"], ["a/b"], [5], None])
def test_bad_allowed_sets_rejected(tmp_path, sets):
    with pytest.raises(ValueError, match="allowed_sets"):
        load_config(_with_repo(tmp_path, allowed_sets=sets))


def test_missing_allowed_sets_rejected(tmp_path):
    files = write_config(tmp_path)
    data = json.loads(files["config"].read_text())
    del data["repos"]["flake-playground"]["allowed_sets"]
    files["config"].write_text(json.dumps(data))
    with pytest.raises(ValueError, match="allowed_sets"):
        load_config(files["config"])


@pytest.mark.parametrize("max_roots", [0, -1, "8", 1.5, True, None])
def test_bad_max_roots_rejected(tmp_path, max_roots):
    with pytest.raises(ValueError, match="max_roots"):
        load_config(_with_repo(tmp_path, max_roots=max_roots))


def _with_top(tmp_path, **fields):
    files = write_config(tmp_path)
    data = json.loads(files["config"].read_text())
    for k, v in fields.items():
        if v is _MISSING:
            del data[k]
        else:
            data[k] = v
    files["config"].write_text(json.dumps(data))
    return files["config"]


_MISSING = object()


def test_import_min_free_bytes_loaded(tmp_path):
    assert make_config(tmp_path).import_min_free_bytes == 10 << 30


@pytest.mark.parametrize("value", [0, -1, "10", 1.5, True, None, _MISSING])
def test_bad_import_min_free_bytes_rejected(tmp_path, value):
    with pytest.raises(ValueError, match="import_min_free_bytes"):
        load_config(_with_top(tmp_path, import_min_free_bytes=value))


def test_disk_alert_percent_loaded(tmp_path):
    assert make_config(tmp_path).disk_alert_percent == 85


@pytest.mark.parametrize("value", [1, 99])
def test_disk_alert_percent_bounds_accepted(tmp_path, value):
    assert load_config(_with_top(tmp_path, disk_alert_percent=value)).disk_alert_percent == value


@pytest.mark.parametrize("value", [0, 100, -5, "85", 85.0, True, None, _MISSING])
def test_bad_disk_alert_percent_rejected(tmp_path, value):
    with pytest.raises(ValueError, match="disk_alert_percent"):
        load_config(_with_top(tmp_path, disk_alert_percent=value))
