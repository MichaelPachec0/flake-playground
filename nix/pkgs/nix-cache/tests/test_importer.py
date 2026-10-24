import json
import os
from types import SimpleNamespace

import pytest

from helpers import (
    bundle_members,
    nar_bytes,
    zstd_bytes,
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
        self.estimates: dict[str, int] = {}
        self.estimated: list[list[str]] = []
        self.estimate_error: str | None = None
        # Non-empty by default: the importer refuses an empty store graph.
        self.graph: dict[str, dict] = {store_path(90, "filler"): {"narSize": 0, "references": [], "registrationTime": 0}}
        self.graph_reads = 0

    def invalid_paths(self, paths):
        return {p for p in paths if p not in self.valid}

    def realise(self, paths):
        bad = set(paths) & self.unsubstitutable
        if bad:
            raise NixError(f"cannot substitute {sorted(bad)[0]}")
        self.realised.extend(sorted(paths))
        self.valid.update(paths)

    def fetch_estimate(self, paths):
        # Like nix-store --dry-run: an unsubstitutable path is "unknown" and fails.
        self.estimated.append(sorted(paths))
        if self.estimate_error:
            raise NixError(self.estimate_error)
        bad = set(paths) & self.unsubstitutable
        if bad:
            raise NixError(f"don't know how to build {sorted(bad)[0]}")
        return sum(self.estimates.get(p, 0) for p in paths)

    def path_info(self, paths=(), *, all_paths=False, **kw):
        assert all_paths
        self.graph_reads += 1
        return self.graph

    def verify_sigs(self, url, paths, keys):
        self.verified.append((url, list(paths), list(keys)))
        if self.verify_error:
            raise NixError(self.verify_error)

    def copy_no_recursive(self, url, paths):
        self.copied.extend(paths)
        self.valid.update(paths)


class FakeFs:
    def __init__(self):
        self.free = 1 << 50
        self.error: OSError | None = None
        self.paths: list[str] = []

    def statvfs(self, path):
        self.paths.append(path)
        if self.error:
            raise self.error
        return SimpleNamespace(f_bavail=self.free, f_frsize=1, f_blocks=1 << 51)


@pytest.fixture
def fake_nix(monkeypatch):
    fake = FakeNix()
    for name in ("invalid_paths", "realise", "fetch_estimate", "path_info", "verify_sigs", "copy_no_recursive"):
        monkeypatch.setattr(nixcli, name, getattr(fake, name))
    fake.fs = FakeFs()
    monkeypatch.setattr(os, "statvfs", fake.fs.statvfs)
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


def test_upstream_only_root_is_rejected(cfg, fake_nix):
    # An upstream path is not valid on the host and carries no repo signature:
    # a manifest-only bundle must not make the host substitute it.
    drop(cfg, bundle_members(manifest([GLIBC], []), {}))
    rejected(cfg, fake_nix, f"1 root(s) are neither in the bundle nor on this host; first: {GLIBC}")
    assert fake_nix.realised == [] and fake_nix.copied == []


def test_mixed_bundle_with_absent_outside_root_is_rejected(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A, GLIBC], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, f"neither in the bundle nor on this host; first: {GLIBC}")
    assert fake_nix.realised == [] and fake_nix.copied == []


def test_outside_root_valid_on_host_is_repinned_not_realised(cfg, fake_nix):
    fake_nix.valid.add(B)
    drop(cfg, bundle_members(manifest([A, B], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=1000)
    assert fake_nix.realised == [] and fake_nix.copied == [A]
    [p] = list_pins(cfg.pins_dir)
    assert set(p.targets) == {A, B}


def test_rejects_set_not_allowed_for_repo(cfg, fake_nix):
    # Path-less bundles need no signature, so the set allowlist is what bounds
    # how many namespaces an upload-key holder can create.
    fake_nix.valid.add(A)
    drop(cfg, bundle_members(manifest([A], [], set_="other"), {}))
    rejected(cfg, fake_nix, "set 'other' is not allowed for flake-playground (allowed: gate, many)")


def test_allowed_sets_are_accepted(cfg, fake_nix):
    fake_nix.valid.add(A)
    drop(cfg, bundle_members(manifest([A], [], set_="many"), {}))
    importer.run(cfg, "flake-playground", now=1000)
    [p] = list_pins(cfg.pins_dir)
    assert str(p.namespace) == "flake-playground/many/x86_64-linux"


def test_rejects_more_roots_than_max_roots(cfg, fake_nix):
    roots = [store_path(100 + i, f"r{i}") for i in range(9)]  # max_roots is 8 in make_config
    fake_nix.valid.update(roots)
    drop(cfg, bundle_members(manifest(roots, []), {}))
    rejected(cfg, fake_nix, "9 roots, cap is 8")
    assert fake_nix.realised == []


def test_max_roots_is_inclusive(cfg, fake_nix):
    roots = [store_path(100 + i, f"r{i}") for i in range(8)]
    fake_nix.valid.update(roots)
    drop(cfg, bundle_members(manifest(roots, []), {}))
    importer.run(cfg, "flake-playground", now=1000)
    [p] = list_pins(cfg.pins_dir)
    assert len(p.targets) == 8


def test_forged_repo_field_is_ignored(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A], [A], repo="someone-else"), {A: narinfo_text(A, sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=1000)
    [p] = list_pins(cfg.pins_dir)
    assert p.namespace.repo == "flake-playground"


def test_unexpected_error_rejects_instead_of_looping(cfg, fake_nix, monkeypatch):
    # Anything outside REJECT_ERRORS (ENOSPC, EIO, a bug) must still move the
    # bundle out of incoming/: left there, the path unit would restart the
    # importer on it over and over.
    def boom(*args, **kwargs):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(importer, "extract_bundle", boom)
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "internal error: OSError: [Errno 28] No space left on device")


def test_unexpected_error_spares_later_bundles(cfg, fake_nix, monkeypatch):
    fake_nix.valid.add(A)
    real = importer.import_bundle
    calls = []

    def flaky(bundle, *args, **kwargs):
        calls.append(bundle.name)
        if len(calls) == 1:
            raise RuntimeError("bug")
        return real(bundle, *args, **kwargs)

    monkeypatch.setattr(importer, "import_bundle", flaky)
    drop(cfg, bundle_members(manifest([A], []), {}), "1700000000-1.tar.zst")
    drop(cfg, bundle_members(manifest([A], []), {}), "1700000001-1.tar.zst")
    assert importer.run(cfg, "flake-playground", now=1000) == 0
    repo = cfg.repos["flake-playground"]
    assert [p.name for p in repo.failed.glob("*.reason")] == ["1700000000-1.tar.zst.reason"]
    assert "internal error: RuntimeError: bug" in (repo.failed / "1700000000-1.tar.zst.reason").read_text()
    assert len(list_pins(cfg.pins_dir)) == 1
    assert list(repo.incoming.iterdir()) == []


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


# --- size guards (budget, free-space floor) -------------------------------
# make_config: budget_bytes 1000, import_min_free_bytes 10 GiB, protect 24 h.
FLOOR = 10 << 30
X = store_path(9, "x")  # already on the host, freshly registered: protected


def fresh(size, now=1000):
    return {"narSize": size, "references": [], "deriver": None, "registrationTime": now}


def no_import(fake_nix):
    assert fake_nix.realised == [] and fake_nix.copied == []


def test_unsubstitutable_outside_reference_is_rejected(cfg, fake_nix):
    fake_nix.unsubstitutable.add(GLIBC)
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, references=[GLIBC], sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "outside the bundle")
    no_import(fake_nix)


def test_over_budget_is_rejected_before_any_download(cfg, fake_nix):
    fake_nix.estimates[GLIBC] = 600
    fake_nix.graph = {X: fresh(397)}
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, references=[GLIBC], sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "bundle would add 604 bytes to 397 protected bytes, over the budget of 1000")
    assert fake_nix.estimated == [[GLIBC]]
    no_import(fake_nix)


def test_exactly_at_budget_is_accepted(cfg, fake_nix):
    fake_nix.estimates[GLIBC] = 600
    fake_nix.graph = {X: fresh(396)}
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, references=[GLIBC], sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=1000)
    assert fake_nix.realised == [GLIBC] and fake_nix.copied == [A]
    assert [p.targets for p in list_pins(cfg.pins_dir)] == [(A,)]


def test_free_space_floor_breach_is_rejected(cfg, fake_nix):
    fake_nix.estimates[GLIBC] = 6
    fake_nix.fs.free = FLOOR + 9
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, references=[GLIBC], sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, f"bundle would leave {FLOOR - 1} bytes free on /nix/store, below the floor of {FLOOR}")
    assert fake_nix.fs.paths and set(fake_nix.fs.paths) == {"/nix/store"}
    no_import(fake_nix)


def test_free_space_floor_is_inclusive(cfg, fake_nix):
    fake_nix.fs.free = FLOOR + 4
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=1000)
    assert fake_nix.copied == [A]


def test_unreadable_free_space_rejects(cfg, fake_nix):
    fake_nix.fs.error = OSError(5, "Input/output error")
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "cannot read free space on /nix/store")
    no_import(fake_nix)


def test_nothing_new_bypasses_both_guards(cfg, fake_nix):
    # Re-pinning paths the host already has never fails on budget or space,
    # even when protected paths alone are over the budget and the disk is full.
    fake_nix.valid.update([A, B])
    fake_nix.graph = {X: fresh(5000)}
    fake_nix.fs.free = 0
    drop(cfg, bundle_members(manifest([A, B], [A]), {A: narinfo_text(A, references=[B], sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=1000)
    assert [set(p.targets) for p in list_pins(cfg.pins_dir)] == [{A, B}]
    assert fake_nix.estimated == [] and fake_nix.graph_reads == 0 and fake_nix.fs.paths == []


def test_bundled_nar_size_counts_toward_new_bytes(cfg, fake_nix):
    fake_nix.graph = {X: fresh(401)}
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG, nar_size=600)}))
    rejected(cfg, fake_nix, "bundle would add 600 bytes to 401 protected bytes")
    no_import(fake_nix)


def test_already_valid_bundled_paths_do_not_count(cfg, fake_nix):
    fake_nix.valid.add(A)
    fake_nix.graph = {X: fresh(990)}
    drop(cfg, bundle_members(
        manifest([A, B], [A, B]),
        {A: narinfo_text(A, sigs=REPO_SIG, nar_size=600), B: narinfo_text(B, sigs=REPO_SIG, nar_size=10)},
    ))
    importer.run(cfg, "flake-playground", now=1000)
    assert [set(p.targets) for p in list_pins(cfg.pins_dir)] == [{A, B}]


def test_estimate_failure_rejects_fail_closed(cfg, fake_nix):
    fake_nix.estimate_error = "unexpected nix-store --dry-run output: 'this derivation will be built:'"
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, references=[GLIBC], sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "this derivation will be built")
    no_import(fake_nix)


def test_budget_counts_pinned_and_probed_paths(cfg, fake_nix):
    # Protection comes from the pins dir and the stats DB, not only from the graph.
    from nix_cache.db import open_db
    from nix_cache.graph import store_hash
    from nix_cache.pins import Namespace, pin

    probed = store_path(10, "probed")
    now = 10 * 86400  # registrations at 0 are outside the 24 h protection window
    with importer.locked(cfg.lock_file):
        pin(cfg.pins_dir, Namespace("flake-playground", "gate", "x86_64-linux"), [X], now - 100)
    conn = open_db(cfg.db)
    conn.execute("INSERT INTO paths(hash, last_narinfo_hit) VALUES (?, ?)", (store_hash(probed), now - 50))
    conn.commit()
    conn.close()
    fake_nix.graph = {X: fresh(500, now=0), probed: fresh(497, now=0), store_path(11, "old"): fresh(9000, now=0)}
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=now)
    reasons = list(cfg.repos["flake-playground"].failed.glob("*.reason"))
    assert [r.read_text() for r in reasons] == [
        "bundle would add 4 bytes to 997 protected bytes, over the budget of 1000\n"
    ]


# --- NAR sizes are checked before anything trusts NarSize -----------------


def test_nar_bomb_is_rejected_before_any_import(cfg, fake_nix):
    # Correct hash and a tiny NarSize would slip past both size guards; the
    # decompressed NAR is counted against NarSize before check_size and copy.
    drop(cfg, bundle_members(
        manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG, nar_size=10)}, nars={A: zstd_bytes(bytes(1 << 20))},
    ))
    rejected(cfg, fake_nix, "more than its NarSize of 10")
    assert fake_nix.estimated == []
    no_import(fake_nix)


def test_nar_shorter_than_nar_size_is_rejected(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG, nar_size=10)}, nars={A: nar_bytes(9)}))
    rejected(cfg, fake_nix, "9 bytes, NarSize says 10")
    no_import(fake_nix)


def test_nar_matching_nar_size_is_accepted(cfg, fake_nix):
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG, nar_size=10)}, nars={A: nar_bytes(10)}))
    importer.run(cfg, "flake-playground", now=1000)
    assert fake_nix.copied == [A]


def test_empty_store_graph_rejects(cfg, fake_nix):
    # Mirror the pruner: an empty path-info --all means the store query is
    # broken, so protected bytes cannot be trusted to be 0.
    fake_nix.graph = {}
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, "nix path-info --all returned no store paths")
    no_import(fake_nix)


def test_claimed_nar_size_over_budget_rejected_before_verify(cfg, fake_nix):
    # A signed path with a genuinely huge NarSize is turned away on the claim
    # alone: no signature check, no decompression, no download, no copy.
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG, nar_size=2000)}))
    rejected(cfg, fake_nix, "bundle would add 2000 bytes to 0 protected bytes, over the budget of 1000")
    assert fake_nix.verified == [] and fake_nix.estimated == []
    no_import(fake_nix)


def test_claimed_nar_size_below_floor_rejected_before_verify(cfg, fake_nix):
    fake_nix.fs.free = FLOOR + 3
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, sigs=REPO_SIG)}))
    rejected(cfg, fake_nix, f"bundle would leave {FLOOR - 1} bytes free")
    assert fake_nix.verified == []
    no_import(fake_nix)


def test_store_graph_is_read_once_per_bundle(cfg, fake_nix):
    fake_nix.estimates[GLIBC] = 5
    drop(cfg, bundle_members(manifest([A], [A]), {A: narinfo_text(A, references=[GLIBC], sigs=REPO_SIG)}))
    importer.run(cfg, "flake-playground", now=1000)
    assert fake_nix.copied == [A] and fake_nix.graph_reads == 1
