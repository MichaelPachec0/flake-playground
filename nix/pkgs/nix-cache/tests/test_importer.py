import json
import os

import pytest

from helpers import (
    bundle_members,
    make_config,
    manifest,
    narinfo_text,
    store_path,
    write_bundle,
)
from nix_cache import importer, nixcli
from nix_cache.nixcli import NixError
from nix_cache.pins import latest_stamps, list_pins

REPO_SIG = ("vmtest-repo-1:c2ln",)
OTHER_SIG = ("vmtest-wrong-1:c2ln",)
A = store_path(1, "a")
B = store_path(2, "b")  # referenced by A, not in the bundle
GLIBC = store_path(3, "glibc")  # "upstream" reference, not valid locally yet


class FakeNix:
    def __init__(self):
        self.valid: set[str] = set()
        self.copied: list[str] = []
        self.realised: list[str] = []
        self.verified: list[tuple] = []
        self.verify_error: str | None = None
        self.unsubstitutable: set[str] = set()

    def invalid_paths(self, paths):
        return {p for p in paths if p not in self.valid}

    def realise(self, paths):
        bad = set(paths) & self.unsubstitutable
        if bad:
            raise NixError(f"cannot substitute {sorted(bad)[0]}")
        self.realised.extend(sorted(paths))
        self.valid.update(paths)

    def verify_sigs(self, url, paths, keys):
        self.verified.append((url, list(paths), list(keys)))
        if self.verify_error:
            raise NixError(self.verify_error)

    def copy_no_recursive(self, url, paths):
        self.copied.extend(paths)
        self.valid.update(paths)


@pytest.fixture
def fake_nix(monkeypatch):
    fake = FakeNix()
    for name in ("invalid_paths", "realise", "verify_sigs", "copy_no_recursive"):
        monkeypatch.setattr(nixcli, name, getattr(fake, name))
    return fake


@pytest.fixture
def cfg(tmp_path):
    return make_config(tmp_path)


def drop(cfg, members, name="1700000000-1.tar.zst"):
    return write_bundle(cfg.repos["flake-playground"].incoming, members, name)


def alerts(cfg):
    return [json.loads(p.read_text()) for p in sorted(cfg.spool.glob("*.json"))]


def test_happy_path_imports_and_pins(cfg, fake_nix):
    fake_nix.valid.add(B)
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, references=[A, B, GLIBC], sigs=REPO_SIG)}))
    assert importer.run(cfg, "flake-playground", now=1000) == 0
    assert fake_nix.realised == [GLIBC]
    assert fake_nix.copied == [A]
    url, paths, keys = fake_nix.verified[0]
    assert url.startswith("file://") and paths == [A]
    assert keys == list(cfg.repos["flake-playground"].trusted_keys)
    [p] = list_pins(cfg.pins_dir)
    assert str(p.namespace) == "flake-playground/gate/x86_64-linux" and p.targets == (A,)
    assert list(cfg.repos["flake-playground"].incoming.iterdir()) == []
    assert alerts(cfg) == []


def test_manifest_only_bundle_pins_existing_roots(cfg, fake_nix):
    fake_nix.valid.add(A)
    drop(cfg, bundle_members(manifest([A], []), {}))
    importer.run(cfg, "flake-playground", now=1000)
    assert fake_nix.copied == [] and fake_nix.verified == []
    assert [p.targets for p in list_pins(cfg.pins_dir)] == [(A,)]


def rejected(cfg, fake_nix, match):
    importer.run(cfg, "flake-playground", now=1000)
    repo = cfg.repos["flake-playground"]
    reasons = list(repo.failed.glob("*.reason"))
    assert len(reasons) == 1, "bundle should be rejected"
    assert match in reasons[0].read_text()
    assert list(repo.incoming.iterdir()) == []
    assert list_pins(cfg.pins_dir) == []
    assert any(match in a["body"] for a in alerts(cfg))


def test_rejects_unsigned(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=())}))
    rejected(cfg, fake_nix, "carry no signature from vmtest-repo-1")


def test_rejects_other_repo_key(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=OTHER_SIG)}))
    rejected(cfg, fake_nix, "carry no signature")


def test_rejects_mixed_signatures(cfg, fake_nix):
    # One path signed by this repo, one only by another key: the whole bundle goes.
    drop(cfg, bundle_members(
        manifest([A], [A, B]),
        {A: narinfo_text(A, references=[A, B], sigs=REPO_SIG), B: narinfo_text(B, sigs=OTHER_SIG)},
    ))
    rejected(cfg, fake_nix, f"1 path(s) carry no signature from vmtest-repo-1; first: {B}")
    assert fake_nix.copied == []


def test_rejects_bad_signature_bits(cfg, fake_nix):
    fake_nix.verify_error = "signature mismatch"
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "signature or content check failed")


def test_rejects_paths_mismatch(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A], []), {A: narinfo_text(A, sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "manifest paths do not match")


def test_rejects_unknown_root(cfg, fake_nix):
    fake_nix.unsubstitutable.add(A)
    drop(cfg, bundle_members(manifest([A], []), {}))
    rejected(cfg, fake_nix, "neither on this host nor substitutable")


def test_upstream_root_is_substituted(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([GLIBC], []), {}))
    importer.run(cfg, "flake-playground", now=1000)
    assert fake_nix.realised == [GLIBC]
    assert [p.targets for p in list_pins(cfg.pins_dir)] == [(GLIBC,)]


def test_forged_repo_field_is_ignored(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A], [A], repo="someone-else"), {A: narinfo_text(A, sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=1000)
    [p] = list_pins(cfg.pins_dir)
    assert p.namespace.repo == "flake-playground"


def test_rejection_keeps_previous_pins(cfg, fake_nix):
    fake_nix.valid.add(A)
    drop(cfg, bundle_members(manifest([A], []), {}), "1700000000-1.tar.zst")
    importer.run(cfg, "flake-playground", now=1000)
    drop(cfg, bundle_members(manifest([B], [B]), {B: narinfo_text(B, sigs=())}), "1700000001-1.tar.zst")
    importer.run(cfg, "flake-playground", now=2000)
    assert [p.stamp for p in list_pins(cfg.pins_dir)] == [1000]
    assert list(latest_stamps(cfg.pins_dir).values()) == [1000]


def test_pending_overflow_is_rejected(cfg, fake_nix):
    fake_nix.valid.add(A)
    for i in range(6):  # max_pending is 4 in make_config
        drop(cfg, bundle_members(manifest([A], []), {}), f"170000000{i}-1.tar.zst")
    importer.run(cfg, "flake-playground", now=1000)
    assert len(list_pins(cfg.pins_dir)) == 4
    assert len(list(cfg.repos["flake-playground"].failed.glob("*.reason"))) == 2


def test_ignores_partial_and_foreign_files(cfg, fake_nix):
    incoming = cfg.repos["flake-playground"].incoming
    (incoming / "part.1.2").write_text("x")
    (incoming / "notes.txt").write_text("x")
    importer.run(cfg, "flake-playground", now=1000)
    assert sorted(p.name for p in incoming.iterdir()) == ["notes.txt", "part.1.2"]


def test_failed_entries_expire_after_7_days(cfg, fake_nix):
    failed = cfg.repos["flake-playground"].failed
    old = failed / "old.tar.zst"
    old.write_text("x")
    os.utime(old, (0, 0))
    importer.run(cfg, "flake-playground", now=8 * 86400)
    assert not old.exists()


def test_main_unknown_repo(cfg, capsys, tmp_path):
    assert importer.main(["--config", str(tmp_path / "config.json"), "--repo", "nope"]) == 2
