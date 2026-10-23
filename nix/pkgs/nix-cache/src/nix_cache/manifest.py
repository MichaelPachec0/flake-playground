"""manifest.json: the per-bundle contract between CI and the importer (schema version 1).

Any key other than the ones below is ignored. In particular a `repo` key is
never trusted: the importer derives the repo from the drop directory a bundle
arrived in, so one repo's upload key cannot file paths under another repo.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

SET_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ARCHES = frozenset({"x86_64-linux", "aarch64-linux"})
# Nix base32 has no e, o, t or u.
STORE_PATH_RE = re.compile(r"^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+$")
MAX_ROOTS = 10_000


class ManifestError(ValueError):
    """manifest.json is missing, malformed or violates the schema."""


@dataclass(frozen=True)
class Manifest:
    set: str
    arch: str
    roots: tuple[str, ...]
    paths: tuple[str, ...]
    run_id: str = ""
    commit: str = ""


def _store_paths(value: object, field: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(
        isinstance(p, str) and STORE_PATH_RE.match(p) for p in value
    ):
        raise ManifestError(f"{field} must be a list of store paths")
    if len(set(value)) != len(value):
        raise ManifestError(f"{field} contains duplicates")
    return tuple(sorted(value))


def parse_manifest(text: str) -> Manifest:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise ManifestError(f"manifest.json is not valid JSON: {e}") from e
    if not isinstance(data, dict):
        raise ManifestError("manifest.json must be a JSON object")
    if data.get("version") != 1:
        raise ManifestError(f"unsupported manifest version {data.get('version')!r}")
    set_ = data.get("set")
    if not isinstance(set_, str) or not SET_RE.match(set_):
        raise ManifestError(f"set {set_!r} must match {SET_RE.pattern}")
    arch = data.get("arch")
    if not isinstance(arch, str) or arch not in ARCHES:
        raise ManifestError(f"arch {arch!r} is not one of {sorted(ARCHES)}")
    roots = _store_paths(data.get("roots"), "roots")
    if not roots:
        raise ManifestError("roots must not be empty")
    if len(roots) > MAX_ROOTS:
        raise ManifestError(f"more than {MAX_ROOTS} roots")
    paths = _store_paths(data.get("paths", []), "paths")
    return Manifest(
        set=set_,
        arch=arch,
        roots=roots,
        paths=paths,
        run_id=str(data.get("run_id", "")),
        commit=str(data.get("commit", "")),
    )


def render_manifest(m: Manifest) -> str:
    return (
        json.dumps(
            {
                "version": 1,
                "set": m.set,
                "arch": m.arch,
                "roots": list(m.roots),
                "paths": list(m.paths),
                "run_id": m.run_id,
                "commit": m.commit,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
