"""Shared test helpers: fake store paths, narinfos, bundle tarballs, configs."""

from __future__ import annotations

import io
import json
import re
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


def narinfo_text(path, *, references=(), sigs=("vmtest-repo-1:c2ln",), deriver=None, nar_size=4) -> str:
    lines = [
        f"StorePath: {path}",
        f"URL: {nar_url(path)}",
        "Compression: zstd",
        "FileHash: sha256:" + "1" * 52,
        "FileSize: 4",
        "NarHash: sha256:" + "1" * 52,
        f"NarSize: {nar_size}",
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


def nar_bytes(size: int) -> bytes:
    """A zstd-compressed stand-in NAR that decompresses to exactly size bytes."""
    return zstd_bytes(b"N" * size)


def bundle_members(manifest_doc: dict, narinfos: dict[str, str], nars: dict[str, bytes] | None = None) -> list:
    """nars overrides the NAR file bytes of a path; by default each NAR is
    zstd data whose decompressed size matches the narinfo's NarSize."""
    members = [
        file_member("nix-cache-info", b"StoreDir: /nix/store\n"),
        file_member("manifest.json", json.dumps(manifest_doc).encode()),
    ]
    if narinfos:
        members.append(dir_member("nar"))
    for path, text in narinfos.items():
        members.append(file_member(Path(path).name[:32] + ".narinfo", text.encode()))
        if nars and path in nars:
            data = nars[path]
        else:
            data = nar_bytes(int(re.search(r"^NarSize: ([0-9]+)$", text, re.M).group(1)))
        members.append(file_member(nar_url(path), data))
    return members


def write_bundle(directory: Path, members, name: str = "1700000000-1.tar.zst") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(zstd_bytes(tar_bytes(members)))
    return path


def write_config(tmp_path: Path, **overrides) -> dict[str, Path]:
    """Write config.json and create its dirs; plain paths only, no nix_cache import."""
    drop = tmp_path / "drop" / "flake-playground"
    for sub in ("incoming", "tmp", "failed"):
        (drop / sub).mkdir(parents=True, exist_ok=True)
    data = {
        "state_dir": str(tmp_path / "state"),
        "gcroots_dir": str(tmp_path / "gcroots"),
        "access_log": str(tmp_path / "access.log"),
        "budget_bytes": 1000,
        "active_days": 30,
        "protect_hours": 24,
        "import_min_free_bytes": 10 << 30,
        "disk_alert_percent": 85,
        "system_roots": [],
        "repos": {
            "flake-playground": {
                "drop_dir": str(drop),
                "trusted_keys": ["vmtest-repo-1:PKOUrEE06/Lg0wbDuGrjHbhekffk1kRlBPaYXDA/hc4="],
                "max_bundle_bytes": 1 << 20,
                "max_unpacked_bytes": 4 << 20,
                "max_pending": 4,
                "max_roots": 8,
                "allowed_sets": ["gate", "many"],
                "upload_key_expiry": ["20991231"],
            }
        },
    }
    data.update(overrides)
    path = tmp_path / "config.json"
    path.write_text(json.dumps(data))
    state = Path(data["state_dir"])
    pins = Path(data["gcroots_dir"]) / "pins"
    state.mkdir(parents=True, exist_ok=True)
    pins.mkdir(parents=True, exist_ok=True)
    return {
        "config": path,
        "drop": drop,
        "incoming": drop / "incoming",
        "failed": drop / "failed",
        "state": state,
        "pins": pins,
    }


def make_config(tmp_path: Path, **overrides):
    from nix_cache.config import load_config

    return load_config(write_config(tmp_path, **overrides)["config"])
