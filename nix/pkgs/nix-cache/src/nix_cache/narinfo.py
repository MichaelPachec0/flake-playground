"""Parse .narinfo files from an uploaded bundle (never trusted)."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .manifest import STORE_PATH_RE

STORE_DIR = "/nix/store"
NAR_URL_RE = re.compile(r"^nar/[0-9a-df-np-sv-z]{52}\.nar(\.(zst|xz|bz2))?$")
BASENAME_RE = re.compile(r"^[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+$")
REQUIRED = ("StorePath", "URL", "NarHash", "NarSize")
# Nix decompresses a NAR by the Compression field (a missing one means
# bzip2), not by the URL, so the two must agree for the importer's own size
# check to read the NAR the way the daemon will. Only zstd (what the bundler
# emits) and none are accepted: Python's xz/bzip2 decoders and the daemon's
# libarchive differ on trailing data, so their byte counts could disagree.
URL_SUFFIX_BY_COMPRESSION = {"none": ".nar", "zstd": ".nar.zst"}


class NarInfoError(ValueError):
    """A narinfo is malformed or points outside the bundle layout."""


@dataclass(frozen=True)
class NarInfo:
    store_path: str
    url: str
    nar_hash: str
    nar_size: int
    compression: str
    references: tuple[str, ...]
    deriver: str | None
    sigs: tuple[str, ...]

    @property
    def key_names(self) -> frozenset[str]:
        return frozenset(s.split(":", 1)[0] for s in self.sigs)


def parse_narinfo(text: str) -> NarInfo:
    fields: dict[str, str] = {}
    sigs: list[str] = []
    for line in text.splitlines():
        if not line:
            continue
        key, sep, value = line.partition(": ")
        if not sep:
            raise NarInfoError(f"malformed narinfo line {line!r}")
        if key == "Sig":
            sigs.append(value)
        elif key in fields:
            raise NarInfoError(f"duplicate narinfo field {key}")
        else:
            fields[key] = value
    for required in REQUIRED:
        if required not in fields:
            raise NarInfoError(f"narinfo lacks {required}")
    store_path = fields["StorePath"]
    if not STORE_PATH_RE.fullmatch(store_path):
        raise NarInfoError(f"bad StorePath {store_path!r}")
    url = fields["URL"]
    if not NAR_URL_RE.fullmatch(url):
        raise NarInfoError(f"unexpected NAR URL {url!r}")
    if not re.fullmatch(r"[0-9]+", fields["NarSize"]):
        raise NarInfoError(f"bad NarSize {fields['NarSize']!r}")
    nar_size = int(fields["NarSize"])
    compression = fields.get("Compression", "bzip2")
    suffix = URL_SUFFIX_BY_COMPRESSION.get(compression)
    if suffix is None or not url.endswith(suffix):
        raise NarInfoError(f"Compression {compression!r} does not match NAR URL {url!r}")
    references = []
    for ref in fields.get("References", "").split():
        if not BASENAME_RE.fullmatch(ref):
            raise NarInfoError(f"bad reference {ref!r}")
        references.append(f"{STORE_DIR}/{ref}")
    deriver = fields.get("Deriver")
    if deriver == "unknown-deriver":
        deriver = None
    elif deriver is not None:
        if not BASENAME_RE.fullmatch(deriver):
            raise NarInfoError(f"bad Deriver {deriver!r}")
        deriver = f"{STORE_DIR}/{deriver}"
    return NarInfo(
        store_path=store_path,
        url=url,
        nar_hash=fields["NarHash"],
        nar_size=nar_size,
        compression=compression,
        references=tuple(references),
        deriver=deriver,
        sigs=tuple(sigs),
    )
