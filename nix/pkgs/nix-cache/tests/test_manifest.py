import json

import pytest

from helpers import store_path
from nix_cache.manifest import Manifest, ManifestError, parse_manifest, render_manifest

ROOT = store_path(1, "hello-2.12")
DEP = store_path(2, "glibc-2.40")


def doc(**overrides):
    base = {"version": 1, "set": "gate", "arch": "x86_64-linux", "roots": [ROOT], "paths": [ROOT, DEP]}
    base.update(overrides)
    return json.dumps(base)


def test_parse_valid():
    m = parse_manifest(doc(run_id=7, commit="abc"))
    assert m == Manifest("gate", "x86_64-linux", (ROOT,), tuple(sorted([ROOT, DEP])), "7", "abc")


def test_paths_default_to_empty():
    data = json.loads(doc())
    del data["paths"]
    assert parse_manifest(json.dumps(data)).paths == ()


def test_repo_key_is_ignored():
    assert parse_manifest(doc(repo="someone-else")).set == "gate"


@pytest.mark.parametrize(
    "overrides",
    [
        {"version": 2},
        {"set": "Gate"},
        {"set": "../x"},
        {"set": ""},
        {"arch": "riscv64-linux"},
        {"arch": ["x86_64-linux"]},
        {"roots": []},
        {"roots": "/nix/store/x"},
        {"roots": ["/tmp/evil"]},
        {"roots": ["/nix/store/" + "e" * 32 + "-bad"]},  # 'e' is not Nix base32
        {"roots": [ROOT, ROOT]},
        {"paths": ["../../etc/passwd"]},
    ],
)
def test_rejects(overrides):
    with pytest.raises(ManifestError):
        parse_manifest(doc(**overrides))


@pytest.mark.parametrize("text", ["not json", "[]", "null"])
def test_rejects_non_object(text):
    with pytest.raises(ManifestError):
        parse_manifest(text)


def test_render_roundtrip():
    m = Manifest("bump-picr", "aarch64-linux", (ROOT,), (DEP,), "1", "c0ffee")
    assert parse_manifest(render_manifest(m)) == m
