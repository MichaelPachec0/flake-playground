"""Black-box CLI contract. Runs against any implementation:
    NIX_CACHE_BIN=/path/to/bin pytest tests/test_cli.py

Only data builders come from helpers (write_config, bundles, narinfos); none
of them imports nix_cache, so the suite needs no Python package to gate a port.
"""

import base64
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

from helpers import bundle_members, manifest, narinfo_text, store_path, write_bundle, write_config

BIN = Path(os.environ["NIX_CACHE_BIN"]) if "NIX_CACHE_BIN" in os.environ else None
pytestmark = pytest.mark.skipif(BIN is None, reason="set NIX_CACHE_BIN to run the black-box suite")
P = store_path(1, "a")


def run(name, *args, input=None, env=None):
    return subprocess.run([str(BIN / name), *args], input=input, capture_output=True, text=True,
                          env={**os.environ, **(env or {})})


def fake_tool(tmp_path, name, body):
    script = tmp_path / name
    script.write_text(f"#!{sys.executable}\nimport sys\nargs = sys.argv[1:]\n{body}\n")
    script.chmod(0o755)
    return str(script)


def test_htpasswd_entry():
    r = run("nix-cache-htpasswd-entry", "--new", "nyx-g1")
    assert r.returncode == 0
    token, line = r.stdout.splitlines()
    user, hashed = line.split(":", 1)
    raw = base64.b64decode(hashed.removeprefix("{SSHA}"))
    assert user == "nyx-g1" and hashlib.sha1(token.encode() + raw[20:]).digest() == raw[:20]
    assert run("nix-cache-htpasswd-entry", "bad", input=token + "\n").returncode == 2


def test_importer_rejects_unsigned_and_exits_zero(tmp_path):
    paths = write_config(tmp_path)
    write_bundle(paths["incoming"], bundle_members(manifest([P], [P]), {P: narinfo_text(P, sigs=())}))
    store = fake_tool(tmp_path, "nix-store", "")
    r = run("cache-importer", "--config", str(paths["config"]), "--repo", "flake-playground",
            env={"NIX_CACHE_NIX_STORE": store})
    assert r.returncode == 0, r.stderr
    assert list(paths["failed"].glob("*.reason"))


def test_importer_unknown_repo(tmp_path):
    paths = write_config(tmp_path)
    assert run("cache-importer", "--config", str(paths["config"]), "--repo", "nope").returncode == 2


def test_pruner_dry_run_summary(tmp_path):
    paths = write_config(tmp_path)
    info = {P: {"narSize": 10, "references": [], "deriver": None, "registrationTime": 1}}
    nix = fake_tool(tmp_path, "nix", f"print({json.dumps(info)!r})")
    r = run("cache-pruner", "--config", str(paths["config"]), "--dry-run", env={"NIX_CACHE_NIX": nix})
    assert r.returncode == 0, r.stderr
    assert sorted(json.loads(r.stdout)) == ["budget_bytes", "delete_pins", "dry_run", "expired",
                                            "kept_bytes", "kept_paths", "over_budget", "roots"]


def test_bundle_nothing_to_pin(tmp_path):
    roots = tmp_path / "roots.json"
    roots.write_text(json.dumps([P]))
    store = fake_tool(tmp_path, "nix-store", "print('\\n'.join(a for a in args if a.startswith('/nix/store/')))")
    r = run("nix-cache-bundle", "--roots-json", str(roots), "--set", "gate", "--arch", "x86_64-linux",
            "--out", str(tmp_path / "out"), "--no-upstream", env={"NIX_CACHE_NIX_STORE": store})
    assert r.returncode == 2 and "no root" in r.stderr


def test_alert_delivery(tmp_path):
    spool = tmp_path / "alerts"
    spool.mkdir()
    (spool / "1-a.json").write_text(json.dumps({"title": "t", "body": "b"}))
    sent = tmp_path / "sent"
    cmd = fake_tool(tmp_path, "sink", f"open({str(sent)!r}, 'w').write(args[0] + sys.stdin.read())")
    r = run("nix-cache-alert", "--spool", str(spool), "--deferred", str(tmp_path / "deferred"), "--command", cmd)
    assert r.returncode == 0 and sent.read_text() == "tb"


def test_push_bundle_streams_only_bundle_members(tmp_path):
    b = tmp_path / "bundle"
    (b / "nar").mkdir(parents=True)
    (b / "nar" / "x.nar.zst").write_bytes(b"n")
    (b / "log").mkdir()
    narinfo = "a" * 32 + ".narinfo"
    for name in ("manifest.json", "nix-cache-info", narinfo, "stray.txt"):
        (b / name).write_text("x")
    sink = tmp_path / "sink.tar.zst"
    cmd = fake_tool(tmp_path, "sink", f"open({str(sink)!r}, 'wb').write(sys.stdin.buffer.read()); print('ok')")
    r = run("nix-cache-push-bundle", str(b), cmd)
    assert r.returncode == 0 and r.stdout == "ok\n", r.stderr
    raw = subprocess.run(["zstd", "-d", "-c", str(sink)], capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
        names = sorted(tar.getnames())
    assert names == sorted(["manifest.json", "nix-cache-info", narinfo, "nar", "nar/x.nar.zst"])


def test_push_bundle_usage(tmp_path):
    assert run("nix-cache-push-bundle", str(tmp_path)).returncode == 2
    assert run("nix-cache-push-bundle", str(tmp_path), "true").returncode == 2  # no manifest.json
