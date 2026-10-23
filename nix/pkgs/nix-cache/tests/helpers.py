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
