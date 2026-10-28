import os
import subprocess
from pathlib import Path

import pytest

from nix_cache.importer import BUNDLE_RE

SCRIPT = Path(__file__).parent.parent / "cache-receive.sh"


def receive(drop: Path, data: bytes, max_bytes: int = 100, extra_env=None):
    for d in ("tmp", "incoming"):
        (drop / d).mkdir(parents=True, exist_ok=True)
    env = {"DROP_DIR": str(drop), "MAX_BYTES": str(max_bytes), "PATH": os.environ["PATH"], **(extra_env or {})}
    return subprocess.run(["bash", "-euo", "pipefail", str(SCRIPT)], input=data, capture_output=True, env=env)


def test_stores_upload(tmp_path):
    r = receive(tmp_path, b"x" * 100)
    assert r.returncode == 0 and r.stdout == b"ok\n"
    [f] = list((tmp_path / "incoming").iterdir())
    assert BUNDLE_RE.fullmatch(f.name) and f.read_bytes() == b"x" * 100
    assert list((tmp_path / "tmp").iterdir()) == []


def test_refuses_oversize(tmp_path):
    r = receive(tmp_path, b"x" * 101)
    assert r.returncode == 3 and b"exceeds 100 bytes" in r.stderr
    assert list((tmp_path / "incoming").iterdir()) == [] and list((tmp_path / "tmp").iterdir()) == []


def test_refuses_empty(tmp_path):
    r = receive(tmp_path, b"")
    assert r.returncode == 4
    assert list((tmp_path / "incoming").iterdir()) == []


def test_ignores_requested_command(tmp_path):
    victim = tmp_path / "victim"
    victim.write_text("keep me")
    r = receive(tmp_path, b"data", extra_env={"SSH_ORIGINAL_COMMAND": f"rm -f {victim}"})
    assert r.returncode == 0 and victim.exists()
