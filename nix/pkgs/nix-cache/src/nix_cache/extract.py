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


class BundleError(Exception):
    """The bundle is malformed or unsafe; it is rejected as a whole."""


def _member_name(name: str) -> str:
    if name.startswith("/"):
        raise BundleError(f"absolute path in bundle: {name!r}")
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if ".." in parts:
        raise BundleError(f"parent reference in bundle: {name!r}")
    return "/".join(parts)


def extract_bundle(src: Path, dest: Path, max_unpacked_bytes: int) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(
        [ZSTD, "-dcq", "--", str(src)], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    assert proc.stdout is not None and proc.stderr is not None
    total = 0
    try:
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as tar:
                for member in tar:
                    name = _member_name(member.name)
                    if member.isdir():
                        if name not in ("", "nar"):
                            raise BundleError(f"unexpected directory {member.name!r}")
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
                    target.parent.mkdir(exist_ok=True)
                    source = tar.extractfile(member)
                    assert source is not None
                    try:
                        with open(target, "xb") as out:
                            shutil.copyfileobj(source, out)
                    except FileExistsError as e:
                        raise BundleError(f"duplicate member {member.name!r}") from e
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
        if not (dest / required).is_file():
            raise BundleError(f"bundle lacks {required}")
