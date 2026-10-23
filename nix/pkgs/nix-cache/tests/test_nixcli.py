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
if __import__("os").path.exists({str(out)!r} + ".err"):
    sys.stderr.write(open({str(out)!r} + ".err").read())
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


def _dry_run(tmp_path, text):
    (tmp_path / "stdout.err").write_text(text)


P1, P2 = store_path(11, "p1"), store_path(12, "p2")


def test_fetch_estimate_plural(fake_bin, tmp_path):
    _, calls = fake_bin
    _dry_run(tmp_path, f"these 2 paths will be fetched (468.1 MiB download, 1.5 GiB unpacked):\n  {P1}\n  {P2}\n")
    # 1.5 GiB printed with one decimal: up to 1.55 GiB, rounded up.
    assert nixcli.fetch_estimate([P2, P1]) == (31 << 30) // 20 + 1
    argv = calls()[0]["argv"]
    assert argv == ["--option", "print-missing", "true", "--realise", "--dry-run", P1, P2]


def test_fetch_estimate_singular(fake_bin, tmp_path):
    _dry_run(tmp_path, f"this path will be fetched (0.0 KiB download, 273.0 KiB unpacked):\n  {P1}\n")
    assert nixcli.fetch_estimate([P1]) == (5461 * 1024 + 19) // 20


@pytest.mark.parametrize(
    "size, expected",
    [
        ("0.1 KiB", (3 << 10) // 20 + 1),
        ("1024.0 KiB", (20481 << 10) // 20 + 1),
        ("2.0 MiB", (41 << 20) // 20 + 1),
        ("1.0 GiB", (21 << 30) // 20 + 1),
        ("2.1 TiB", (43 << 40) // 20 + 1),
    ],
)
def test_fetch_estimate_units_round_up(fake_bin, tmp_path, size, expected):
    _dry_run(tmp_path, f"this path will be fetched (0.0 KiB download, {size} unpacked):\n  {P1}\n")
    assert nixcli.fetch_estimate([P1]) == expected


def test_fetch_estimate_nothing_to_fetch(fake_bin, tmp_path):
    _dry_run(tmp_path, "")
    assert nixcli.fetch_estimate([P1]) == 0


def test_fetch_estimate_tolerates_warnings(fake_bin, tmp_path):
    _dry_run(tmp_path, f"warning: ignoring untrusted substituter\nthis path will be fetched (1.0 KiB download, 1.0 KiB unpacked):\n  {P1}\n")
    assert nixcli.fetch_estimate([P1]) == (21 << 10) // 20 + 1


def test_fetch_estimate_empty_runs_nothing(fake_bin):
    _, calls = fake_bin
    assert nixcli.fetch_estimate([]) == 0
    assert calls() == []


@pytest.mark.parametrize(
    "text",
    [
        f"this derivation will be built:\n  {P1}\n",
        f"these 2 derivations will be built:\n  {P1}\n  {P2}\n",
        f"don't know how to build these paths:\n  {P1}\n",
        "error: something odd\n",
        "these 2 paths will be fetched (1.0 KiB download, lots unpacked):\n",
        f"this path will be fetched (1.0 KiB download, 1.0 KiB unpacked):\n  {P1}\ngarbage\n",
    ],
)
def test_fetch_estimate_fails_closed(fake_bin, tmp_path, text):
    _dry_run(tmp_path, text)
    with pytest.raises(nixcli.NixError):
        nixcli.fetch_estimate([P1])


def test_fetch_estimate_sums_chunks(fake_bin, tmp_path):
    _, calls = fake_bin
    _dry_run(tmp_path, "this path will be fetched (1.0 KiB download, 1.0 KiB unpacked):\n")
    paths = [store_path(i, "p") for i in range(1200)]
    assert nixcli.fetch_estimate(paths) == 3 * ((21 << 10) // 20 + 1)
    assert len(calls()) == 3


def test_fetch_estimate_command_failure(fake_bin, tmp_path):
    (tmp_path / "stdout.rc").write_text("1")
    with pytest.raises(nixcli.NixError, match=r"failed \(1\)"):
        nixcli.fetch_estimate([P1])


BAD = ["-rf", "/nix/store/x", f"{A}\n{store_path(2, 'b')}", A + "\n", "../etc"]


@pytest.mark.parametrize("bad", BAD)
def test_store_paths_are_validated(fake_bin, bad):
    _, calls = fake_bin
    for fn in (
        nixcli.invalid_paths,
        nixcli.realise,
        nixcli.fetch_estimate,
        nixcli.path_info,
        lambda p: nixcli.verify_sigs("file:///b", p, ["k:AA"]),
        lambda p: nixcli.copy_no_recursive("file:///b", p),
    ):
        with pytest.raises(nixcli.NixError, match="non-store path"):
            fn([A, bad])
    assert calls() == []
