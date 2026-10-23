"""Shared test helpers: fake store paths, narinfos, bundle tarballs, configs."""

from __future__ import annotations

import io
import json
import subprocess
import tarfile
from pathlib import Path

ALPHABET = "0123456789abcdfghijklmnpqrsvwxyz"  # Nix base32


def fake_hash(n: int, length: int = 32) -> str:
    chars = []
    for _ in range(length):
        chars.append(ALPHABET[n % 32])
        n //= 32
    return "".join(reversed(chars))


def store_path(n: int, name: str) -> str:
    return f"/nix/store/{fake_hash(n)}-{name}"


def nar_url(path: str) -> str:
    return f"nar/{Path(path).name[:32]}{'0' * 20}.nar.zst"


def narinfo_text(path, *, references=(), sigs=("vmtest-repo-1:c2ln",), deriver=None) -> str:
    lines = [
        f"StorePath: {path}",
        f"URL: {nar_url(path)}",
        "Compression: zstd",
        "FileHash: sha256:" + "1" * 52,
        "FileSize: 4",
        "NarHash: sha256:" + "1" * 52,
        "NarSize: 4",
        "References: " + " ".join(Path(r).name for r in references),
    ]
    if deriver:
        lines.append(f"Deriver: {Path(deriver).name}")
    lines += [f"Sig: {s}" for s in sigs]
    return "\n".join(lines) + "\n"


def file_member(name: str, data: bytes) -> tuple[tarfile.TarInfo, bytes]:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    return info, data


def dir_member(name: str) -> tuple[tarfile.TarInfo, None]:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    return info, None


def tar_bytes(members) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for info, data in members:
            tar.addfile(info, io.BytesIO(data) if data is not None else None)
    return buf.getvalue()


def zstd_bytes(data: bytes) -> bytes:
    return subprocess.run(["zstd", "-q", "-c"], input=data, capture_output=True, check=True).stdout


def manifest(roots, paths, set_="gate", arch="x86_64-linux", **extra) -> dict:
    return {"version": 1, "set": set_, "arch": arch, "roots": list(roots), "paths": list(paths), **extra}


def bundle_members(manifest_doc: dict, narinfos: dict[str, str]) -> list:
    members = [
        file_member("nix-cache-info", b"StoreDir: /nix/store\n"),
        file_member("manifest.json", json.dumps(manifest_doc).encode()),
    ]
    if narinfos:
        members.append(dir_member("nar"))
    for path, text in narinfos.items():
        members.append(file_member(Path(path).name[:32] + ".narinfo", text.encode()))
        members.append(file_member(nar_url(path), b"NAR!"))
    return members


def write_bundle(directory: Path, members, name: str = "1700000000-1.tar.zst") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(zstd_bytes(tar_bytes(members)))
    return path
