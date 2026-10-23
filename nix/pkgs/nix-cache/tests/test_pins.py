import os

import pytest

from helpers import store_path
from nix_cache.pins import Namespace, delete_pin, latest_stamps, list_pins, pin

NS = Namespace("flake-playground", "gate", "x86_64-linux")
A, B, C = store_path(1, "a"), store_path(2, "b"), store_path(3, "c")


def test_pin_creates_symlinks_and_latest(tmp_path):
    p = pin(tmp_path, NS, [A, B], 100)
    assert p.path == tmp_path / "flake-playground/gate/x86_64-linux/100"
    assert sorted(os.readlink(l) for l in p.path.iterdir()) == [A, B]
    assert os.readlink(p.path.parent / "latest") == "100"
    assert p.targets == (A, B)


def test_same_second_pins_do_not_collide(tmp_path):
    first = pin(tmp_path, NS, [A], 100)
    second = pin(tmp_path, NS, [B], 100)
    assert (first.stamp, second.stamp) == (100, 101)
    assert latest_stamps(tmp_path) == {NS: 101}


@pytest.mark.parametrize("ns", [Namespace("../x", "gate", "x86_64-linux"), Namespace("r", "a/b", "x86_64-linux")])
def test_rejects_bad_names(tmp_path, ns):
    with pytest.raises(ValueError):
        pin(tmp_path, ns, [A], 1)


def test_rejects_trailing_newline_name(tmp_path):
    with pytest.raises(ValueError):
        pin(tmp_path, Namespace("r\n", "gate", "x86_64-linux"), [A], 1)


def test_list_pins(tmp_path):
    pin(tmp_path, NS, [A], 100)
    pin(tmp_path, NS, [B], 200)
    other = Namespace("flake-playground", "gate", "aarch64-linux")
    pin(tmp_path, other, [C], 150)
    pins = list_pins(tmp_path)
    assert [(p.namespace.arch, p.stamp) for p in pins] == [
        ("aarch64-linux", 150),
        ("x86_64-linux", 100),
        ("x86_64-linux", 200),
    ]


def test_list_pins_empty_dir(tmp_path):
    assert list_pins(tmp_path / "missing") == []


def test_delete_older_pin_keeps_latest(tmp_path):
    old = pin(tmp_path, NS, [A], 100)
    pin(tmp_path, NS, [B], 200)
    delete_pin(tmp_path, old)
    assert [p.stamp for p in list_pins(tmp_path)] == [200]
    assert latest_stamps(tmp_path) == {NS: 200}


def test_delete_latest_retargets_to_newest_remaining(tmp_path):
    pin(tmp_path, NS, [A], 100)
    newest = pin(tmp_path, NS, [B], 200)
    delete_pin(tmp_path, newest)
    assert latest_stamps(tmp_path) == {NS: 100}


def test_delete_last_pin_removes_namespace(tmp_path):
    only = pin(tmp_path, NS, [A], 100)
    delete_pin(tmp_path, only)
    assert latest_stamps(tmp_path) == {}
    assert not (tmp_path / "flake-playground").exists()


@pytest.mark.parametrize("bad", ["/etc", "", "/", "/nix/store/../../x", "relative"])
def test_pin_rejects_non_store_roots(tmp_path, bad):
    with pytest.raises(ValueError):
        pin(tmp_path, NS, [A, bad], 1)
    assert not tmp_path.exists() or list(tmp_path.iterdir()) == []


def test_pin_dedupes_roots(tmp_path):
    p = pin(tmp_path, NS, [A, A, B], 1)
    assert p.targets == (A, B)
    assert len(list(p.path.iterdir())) == 2


def test_failed_pin_leaves_no_tmp_and_stale_tmp_swept(tmp_path, monkeypatch):
    import nix_cache.pins as pins

    def boom(*a, **k):
        raise OSError("boom")

    monkeypatch.setattr(pins.os, "symlink", boom)
    with pytest.raises(OSError):
        pin(tmp_path, NS, [A], 100)
    base = NS.dir(tmp_path)
    assert list(base.iterdir()) == []
    monkeypatch.undo()
    (base / ".5.tmp").mkdir()
    (base / ".5.tmp" / "x").symlink_to(A)
    (base / ".6.del").mkdir()
    pin(tmp_path, NS, [A], 100)
    assert sorted(e.name for e in base.iterdir()) == ["100", "latest"]


def test_delete_ignores_stale_tmp_for_namespace_removal(tmp_path):
    only = pin(tmp_path, NS, [A], 100)
    (NS.dir(tmp_path) / ".7.tmp").mkdir()
    delete_pin(tmp_path, only)
    assert not (tmp_path / "flake-playground").exists()


def test_delete_leaves_no_del_dir_and_latest_valid(tmp_path):
    pin(tmp_path, NS, [A], 100)
    newest = pin(tmp_path, NS, [B], 200)
    delete_pin(tmp_path, newest)
    base = NS.dir(tmp_path)
    assert sorted(e.name for e in base.iterdir()) == ["100", "latest"]
    assert (base / "latest").resolve() == (base / "100").resolve()


def test_latest_stamps_falls_back_when_missing_or_dangling(tmp_path):
    pin(tmp_path, NS, [A], 100)
    p2 = pin(tmp_path, NS, [B], 200)
    latest = NS.dir(tmp_path) / "latest"
    latest.unlink()
    assert latest_stamps(tmp_path) == {NS: 200}
    os.symlink("999", latest)
    assert latest_stamps(tmp_path) == {NS: 200}
    assert p2.stamp == 200
