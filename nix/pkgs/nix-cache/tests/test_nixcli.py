import json
import os
import sys

import pytest

from helpers import store_path
from nix_cache import nixcli

A = store_path(1, "a")


@pytest.fixture
def fake_bin(tmp_path, monkeypatch):
    """A fake nix/nix-store that logs argv + stdin and prints canned output."""
    log = tmp_path / "calls.jsonl"
    out = tmp_path / "stdout"
    out.write_text("")
    script = tmp_path / "fake"
    script.write_text(
        f"""#!{sys.executable}
import json, sys
data = sys.stdin.read() if not sys.stdin.isatty() else ""
with open({str(log)!r}, "a") as f:
    f.write(json.dumps({{"argv": sys.argv[1:], "stdin": data}}) + "\\n")
sys.stdout.write(open({str(out)!r}).read())
sys.exit(int(open({str(out)!r} + ".rc").read()) if __import__("os").path.exists({str(out)!r} + ".rc") else 0)
"""
    )
    script.chmod(0o755)
    monkeypatch.setattr(nixcli, "NIX", str(script))
    monkeypatch.setattr(nixcli, "NIX_STORE", str(script))

    def calls():
        return [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []

    return out, calls


def test_invalid_paths_chunks_and_parses(fake_bin):
    out, calls = fake_bin
    out.write_text(store_path(2, "b") + "\n")
    paths = [store_path(i, "p") for i in range(1200)]
    assert nixcli.invalid_paths(paths) == {store_path(2, "b")}
    assert len(calls()) == 3
    assert calls()[0]["argv"][:2] == ["--check-validity", "--print-invalid"]


def test_invalid_paths_empty_runs_nothing(fake_bin):
    _, calls = fake_bin
    assert nixcli.invalid_paths([]) == set()
    assert calls() == []


def test_nix_error_carries_stderr(fake_bin, tmp_path):
    out, _ = fake_bin
    (tmp_path / "stdout.rc").write_text("1")
    with pytest.raises(nixcli.NixError, match=r"failed \(1\)"):
        nixcli.nix("store", "ping")


def test_path_info_uses_stdin(fake_bin):
    out, calls = fake_bin
    out.write_text(json.dumps({A: {"narSize": 1, "references": [], "deriver": None, "registrationTime": 5}}))
    info = nixcli.path_info([A], recursive=True)
    assert info[A]["narSize"] == 1
    call = calls()[0]
    assert call["argv"][-6:] == ["path-info", "--json", "--json-format", "1", "--recursive", "--stdin"]
    assert call["stdin"] == A + "\n"


def test_normalise_list_and_basenames():
    data = [{"path": "/nix/store/a", "references": ["b"], "deriver": "c.drv"}, {"path": "/nix/store/x"}]
    norm = nixcli.normalise_path_info(data)
    assert norm["/nix/store/a"]["references"] == ["/nix/store/b"]
    assert norm["/nix/store/a"]["deriver"] == "/nix/store/c.drv"
    assert norm["/nix/store/x"]["references"] == []


def test_normalise_drops_invalid_entries():
    assert nixcli.normalise_path_info({"/nix/store/a": None}) == {}


def test_verify_sigs_passes_only_given_keys(fake_bin):
    _, calls = fake_bin
    nixcli.verify_sigs("file:///b", [A], ["k-1:AAA", "k-2:BBB"])
    argv = calls()[0]["argv"]
    assert "verify" in argv and "--sigs-needed" in argv
    assert argv[argv.index("trusted-public-keys") + 1] == "k-1:AAA k-2:BBB"


def test_copy_no_recursive(fake_bin):
    _, calls = fake_bin
    nixcli.copy_no_recursive("file:///b", [A])
    argv = calls()[0]["argv"]
    assert argv[argv.index("copy"):] == ["copy", "--no-recursive", "--from", "file:///b", "--to", "daemon", "--stdin"]


BAD = ["-rf", "/nix/store/x", f"{A}\n{store_path(2, 'b')}", A + "\n", "../etc"]


@pytest.mark.parametrize("bad", BAD)
def test_store_paths_are_validated(fake_bin, bad):
    _, calls = fake_bin
    for fn in (
        nixcli.invalid_paths,
        nixcli.realise,
        nixcli.path_info,
        lambda p: nixcli.verify_sigs("file:///b", p, ["k:AA"]),
        lambda p: nixcli.copy_no_recursive("file:///b", p),
    ):
        with pytest.raises(nixcli.NixError, match="non-store path"):
            fn([A, bad])
    assert calls() == []
