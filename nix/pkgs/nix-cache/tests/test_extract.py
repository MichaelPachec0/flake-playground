import tarfile

import pytest

from helpers import (
    bundle_members,
    dir_member,
    file_member,
    manifest,
    narinfo_text,
    nar_url,
    store_path,
    write_bundle,
)
from nix_cache.extract import BundleError, extract_bundle

P = store_path(1, "hello")


def good_members():
    return bundle_members(manifest([P], [P]), {P: narinfo_text(P)})


def extract(tmp_path, members, cap=1 << 20):
    src = write_bundle(tmp_path / "in", members)
    dest = tmp_path / "out"
    extract_bundle(src, dest, cap)
    return dest


def test_extracts_valid_bundle(tmp_path):
    dest = extract(tmp_path, good_members())
    assert (dest / "manifest.json").is_file()
    assert (dest / (P.split("/")[-1][:32] + ".narinfo")).is_file()
    assert (dest / nar_url(P)).read_bytes() == b"NAR!"


def test_manifest_only_bundle_is_valid(tmp_path):
    dest = extract(tmp_path, bundle_members(manifest([P], []), {}))
    assert sorted(p.name for p in dest.iterdir()) == ["manifest.json", "nix-cache-info"]


def test_dot_slash_prefix_is_accepted(tmp_path):
    members = [(info, data) for info, data in good_members()]
    for info, _ in members:
        info.name = "./" + info.name
    extract(tmp_path, members)


def symlink_member():
    info = tarfile.TarInfo("nix-cache-info")
    info.type = tarfile.SYMTYPE
    info.linkname = "/etc/shadow"
    return info, None


def hardlink_member():
    info = tarfile.TarInfo("manifest.json")
    info.type = tarfile.LNKTYPE
    info.linkname = "/etc/shadow"
    return info, None


def device_member():
    info = tarfile.TarInfo("nix-cache-info")
    info.type = tarfile.CHRTYPE
    info.devmajor, info.devminor = 1, 3
    return info, None


@pytest.mark.parametrize(
    "extra",
    [
        file_member("/etc/cron.d/x", b"x"),
        file_member("../escape", b"x"),
        file_member("nar/../../escape", b"x"),
        file_member("random.txt", b"x"),
        file_member("log/abc", b"x"),
        dir_member("realisations"),
        symlink_member(),
        hardlink_member(),
        device_member(),
        file_member("manifest.json", b"{}"),  # duplicate
    ],
)
def test_rejects_unsafe_members(tmp_path, extra):
    with pytest.raises(BundleError):
        extract(tmp_path, good_members() + [extra])


def test_rejects_oversize(tmp_path):
    members = good_members() + [file_member(nar_url(store_path(9, "big")), b"x" * 4096)]
    with pytest.raises(BundleError, match="unpacks to more than"):
        extract(tmp_path, members, cap=1024)


def test_rejects_truncated(tmp_path):
    src = write_bundle(tmp_path / "in", good_members())
    data = src.read_bytes()
    src.write_bytes(data[: len(data) // 2])
    with pytest.raises(BundleError):
        extract_bundle(src, tmp_path / "out", 1 << 20)


def test_rejects_garbage(tmp_path):
    src = tmp_path / "x.tar.zst"
    src.write_bytes(b"definitely not zstd")
    with pytest.raises(BundleError):
        extract_bundle(src, tmp_path / "out", 1 << 20)


def test_requires_manifest(tmp_path):
    members = [m for m in good_members() if m[0].name != "manifest.json"]
    with pytest.raises(BundleError, match="manifest.json"):
        extract(tmp_path, members)
