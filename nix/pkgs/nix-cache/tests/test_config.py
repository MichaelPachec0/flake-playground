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
