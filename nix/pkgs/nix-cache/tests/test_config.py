from pathlib import Path

from helpers import make_config


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
