"""Unpack an uploaded bundle (.tar.zst) without trusting a single byte of it.

tarfile's extraction filters are not used: every member is checked against
the exact bundle layout and copied by hand into a fresh file opened with
O_EXCL, so links, devices, absolute or parent paths, unexpected files and
duplicates can never reach the filesystem.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tarfile
from pathlib import Path

TOP_FILE_RE = re.compile(r"(nix-cache-info|manifest\.json|[0-9a-df-np-sv-z]{32}\.narinfo)")
NAR_FILE_RE = re.compile(r"nar/[0-9a-df-np-sv-z]{52}\.nar(\.(zst|xz|bz2))?")
ZSTD = "zstd"


SLACK_BYTES = 1 << 20  # tar headers and padding on top of the file-data cap
MAX_MEMBERS = 100_000


class BundleError(Exception):
    """The bundle is malformed or unsafe; it is rejected as a whole."""


class _CountingReader:
    """Bound the decompressed stream so header payloads cannot exhaust memory."""

    def __init__(self, raw, limit: int) -> None:
        self._raw = raw
        self._limit = limit
        self._seen = 0

    def read(self, size: int = -1) -> bytes:
        data = self._raw.read(size)
        self._seen += len(data)
        if self._seen > self._limit:
            raise BundleError(f"bundle unpacks to more than {self._limit} bytes")
        return data


def _member_name(name: str) -> str:
    if name.startswith("/"):
        raise BundleError(f"absolute path in bundle: {name!r}")
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if ".." in parts:
        raise BundleError(f"parent reference in bundle: {name!r}")
    return "/".join(parts)


def extract_bundle(src: Path, dest: Path, max_unpacked_bytes: int) -> None:
    """Unpack src into dest, which must be nonexistent or an empty directory.

    On BundleError the caller must discard dest: it may hold partial output.
    """
    if dest.is_symlink() or (dest.exists() and not dest.is_dir()):
        raise BundleError(f"destination {dest} is not a directory")
    if dest.exists() and any(dest.iterdir()):
        raise BundleError(f"destination {dest} is not empty")
    dest.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(
        [ZSTD, "-dcq", "--", str(src)], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    assert proc.stdout is not None and proc.stderr is not None
    total = 0
    count = 0
    seen: set[str] = set()
    stream = _CountingReader(proc.stdout, max_unpacked_bytes + SLACK_BYTES)
    try:
        try:
            with tarfile.open(fileobj=stream, mode="r|") as tar:
                for member in tar:
                    count += 1
                    if count > MAX_MEMBERS:
                        raise BundleError(f"bundle has more than {MAX_MEMBERS} members")
                    name = _member_name(member.name)
                    if member.isdir():
                        if name not in ("", "nar"):
                            raise BundleError(f"unexpected directory {member.name!r}")
                        if name == "nar":
                            nar_dir = dest / "nar"
                            if nar_dir.is_symlink() or (nar_dir.exists() and not nar_dir.is_dir()):
                                raise BundleError("nar is not a directory")
                            nar_dir.mkdir(exist_ok=True)
                        continue
                    if not member.isfile():
                        raise BundleError(f"{member.name!r} is not a regular file")
                    if not (TOP_FILE_RE.fullmatch(name) or NAR_FILE_RE.fullmatch(name)):
                        raise BundleError(f"unexpected file {member.name!r}")
                    total += member.size
                    if total > max_unpacked_bytes:
                        raise BundleError(
                            f"bundle unpacks to more than {max_unpacked_bytes} bytes"
                        )
                    target = dest / name
                    if target.parent != dest:
                        if target.parent.is_symlink():
                            raise BundleError("nar is a symlink")
                        target.parent.mkdir(exist_ok=True)
                    source = tar.extractfile(member)
                    assert source is not None
                    try:
                        with open(target, "xb") as out:
                            shutil.copyfileobj(source, out)
                    except FileExistsError as e:
                        raise BundleError(f"duplicate member {member.name!r}") from e
                    seen.add(name)
        except tarfile.TarError as e:
            raise BundleError(f"corrupt or truncated tar: {e}") from e
    finally:
        proc.stdout.close()
        stderr = proc.stderr.read().decode(errors="replace").strip()
        proc.stderr.close()
        returncode = proc.wait()
    if returncode != 0:
        raise BundleError(f"zstd failed ({returncode}): {stderr}")
    for required in ("nix-cache-info", "manifest.json"):
        if required not in seen:
            raise BundleError(f"bundle lacks {required}")
