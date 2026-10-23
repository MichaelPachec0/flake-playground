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
