import bz2
import io
import lzma
import tarfile
from pathlib import Path

import pytest

from helpers import (
    bundle_members,
    dir_member,
    file_member,
    manifest,
    nar_bytes,
    narinfo_text,
    nar_url,
    store_path,
    write_bundle,
    zstd_bytes,
)
from nix_cache.extract import BundleError, check_nar_size, extract_bundle

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
    assert (dest / nar_url(P)).read_bytes() == nar_bytes(4)


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


def test_rejects_huge_gnu_longname(tmp_path):
    info = tarfile.TarInfo("x" * 3000000)
    info.size = 0
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        tar.addfile(info)
    src = tmp_path / "in.tar.zst"
    src.write_bytes(zstd_bytes(buf.getvalue()))
    with pytest.raises(BundleError, match="unpacks to more than"):
        extract_bundle(src, tmp_path / "out", 1024)


def test_rejects_huge_pax_header(tmp_path):
    info = tarfile.TarInfo("nix-cache-info")
    info.pax_headers = {"comment": "y" * 3000000}
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
        tar.addfile(info)
    src = tmp_path / "in.tar.zst"
    src.write_bytes(zstd_bytes(buf.getvalue()))
    with pytest.raises(BundleError, match="unpacks to more than"):
        extract_bundle(src, tmp_path / "out", 1024)


def test_rejects_too_many_members(tmp_path, monkeypatch):
    monkeypatch.setattr("nix_cache.extract.MAX_MEMBERS", 5)
    members = good_members() + [dir_member("nar") for _ in range(10)]
    with pytest.raises(BundleError, match="more than"):
        extract(tmp_path, members)


def test_rejects_nonempty_dest(tmp_path):
    src = write_bundle(tmp_path / "in", good_members())
    dest = tmp_path / "out"
    dest.mkdir()
    (dest / "manifest.json").write_text("{}")
    with pytest.raises(BundleError, match="not empty"):
        extract_bundle(src, dest, 1 << 20)


def test_accepts_existing_empty_dest(tmp_path):
    src = write_bundle(tmp_path / "in", good_members())
    dest = tmp_path / "out"
    dest.mkdir()
    extract_bundle(src, dest, 1 << 20)
    assert (dest / "manifest.json").is_file()


def test_rejects_dest_that_is_a_file(tmp_path):
    src = write_bundle(tmp_path / "in", good_members())
    dest = tmp_path / "out"
    dest.write_text("x")
    with pytest.raises(BundleError):
        extract_bundle(src, dest, 1 << 20)


def test_missing_required_not_satisfied_by_empty_manifest_member_absent(tmp_path):
    # nix-cache-info absent from the stream must be reported even if dest were reused
    members = [m for m in good_members() if m[0].name != "nix-cache-info"]
    with pytest.raises(BundleError, match="nix-cache-info"):
        extract(tmp_path, members)


# --- NAR size check: decompressed bytes must equal the narinfo's NarSize ----
COMPRESSORS = {
    "zstd": zstd_bytes,
    "xz": lzma.compress,
    "bzip2": bz2.compress,
    "none": lambda b: b,
}


def nar_file(tmp_path, data: bytes) -> Path:
    path = tmp_path / "x.nar"
    path.write_bytes(data)
    return path


@pytest.mark.parametrize("compression", sorted(COMPRESSORS))
def test_nar_size_exact_match_accepted(tmp_path, compression):
    check_nar_size(nar_file(tmp_path, COMPRESSORS[compression](b"z" * 3000)), compression, 3000)


@pytest.mark.parametrize("compression", sorted(COMPRESSORS))
def test_nar_bomb_rejected(tmp_path, compression):
    # NarSize 10, real content 1 MiB of zeros: stop as soon as the count passes 10.
    path = nar_file(tmp_path, COMPRESSORS[compression](bytes(1 << 20)))
    with pytest.raises(BundleError, match="more than its NarSize of 10"):
        check_nar_size(path, compression, 10)


@pytest.mark.parametrize("compression", sorted(COMPRESSORS))
def test_nar_shorter_than_nar_size_rejected(tmp_path, compression):
    path = nar_file(tmp_path, COMPRESSORS[compression](b"z" * 9))
    with pytest.raises(BundleError, match="9 bytes, NarSize says 10"):
        check_nar_size(path, compression, 10)


@pytest.mark.parametrize("compression", ["zstd", "xz", "bzip2"])
def test_corrupt_nar_rejected(tmp_path, compression):
    with pytest.raises(BundleError):
        check_nar_size(nar_file(tmp_path, b"definitely not compressed"), compression, 25)


def test_unknown_compression_rejected(tmp_path):
    with pytest.raises(BundleError, match="unsupported compression"):
        check_nar_size(nar_file(tmp_path, b"x"), "br", 1)
