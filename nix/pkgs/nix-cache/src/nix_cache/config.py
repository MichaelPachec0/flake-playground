"""The JSON config the NixOS module writes for the importer and pruner."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from .manifest import SET_RE

KEY_RE = re.compile(r"[A-Za-z0-9._-]+:[A-Za-z0-9+/]+={0,2}")


def _keys(name: str, keys: object) -> tuple[str, ...]:
    if not isinstance(keys, list) or not keys:
        raise ValueError(f"repo {name!r}: trusted_keys must be a non-empty list")
    for key in keys:
        if not isinstance(key, str) or not KEY_RE.fullmatch(key):
            raise ValueError(f"repo {name!r}: invalid trusted key {key!r}")
    return tuple(keys)


def _sets(name: str, sets: object) -> tuple[str, ...]:
    # The only namespaces a repo's bundles may pin under. Bundles that carry
    # no paths need no signature, so this list is what bounds the namespaces
    # (each one "latest is always kept" while active) an upload key can make.
    if not isinstance(sets, list) or not sets:
        raise ValueError(f"repo {name!r}: allowed_sets must be a non-empty list")
    for s in sets:
        if not isinstance(s, str) or not SET_RE.fullmatch(s):
            raise ValueError(f"repo {name!r}: invalid set name {s!r} in allowed_sets")
    return tuple(sets)


def _positive(name: str, field: str, value: object) -> int:
    if type(value) is not int or value < 1:
        raise ValueError(f"repo {name!r}: {field} must be a positive integer, got {value!r}")
    return value


def _top_int(field: str, value: object, low: int = 1, high: int | None = None) -> int:
    if type(value) is not int or value < low or (high is not None and value > high):
        bound = f"between {low} and {high}" if high is not None else "a positive integer"
        raise ValueError(f"{field} must be {bound}, got {value!r}")
    return value


@dataclass(frozen=True)
class RepoConfig:
    name: str
    drop_dir: Path
    trusted_keys: tuple[str, ...]
    max_bundle_bytes: int
    max_unpacked_bytes: int
    max_pending: int
    max_roots: int
    allowed_sets: tuple[str, ...]
    upload_key_expiry: tuple[str, ...]

    @property
    def incoming(self) -> Path:
        return self.drop_dir / "incoming"

    @property
    def tmp(self) -> Path:
        return self.drop_dir / "tmp"

    @property
    def failed(self) -> Path:
        return self.drop_dir / "failed"


@dataclass(frozen=True)
class Config:
    state_dir: Path
    gcroots_dir: Path
    access_log: Path
    budget_bytes: int
    active_days: int
    protect_hours: int
    # Free space an import must leave on /nix/store (the importer's floor).
    import_min_free_bytes: int
    # The pruner alerts once a day while /nix/store's filesystem is this full.
    disk_alert_percent: int
    system_roots: tuple[str, ...]
    repos: dict[str, RepoConfig]

    @property
    def lock_file(self) -> Path:
        return self.state_dir / "lock"

    @property
    def spool(self) -> Path:
        return self.state_dir / "alerts"

    @property
    def deferred(self) -> Path:
        return self.state_dir / "alerts-deferred"

    @property
    def db(self) -> Path:
        return self.state_dir / "stats.sqlite"

    @property
    def work_dir(self) -> Path:
        return self.state_dir / "work"

    @property
    def pins_dir(self) -> Path:
        return self.gcroots_dir / "pins"


def load_config(path: Path) -> Config:
    data = json.loads(Path(path).read_text())
    repos = {
        name: RepoConfig(
            name=name,
            drop_dir=Path(r["drop_dir"]),
            trusted_keys=_keys(name, r["trusted_keys"]),
            max_bundle_bytes=int(r["max_bundle_bytes"]),
            max_unpacked_bytes=int(r["max_unpacked_bytes"]),
            max_pending=int(r["max_pending"]),
            max_roots=_positive(name, "max_roots", r.get("max_roots")),
            allowed_sets=_sets(name, r.get("allowed_sets")),
            upload_key_expiry=tuple(r.get("upload_key_expiry", [])),
        )
        for name, r in data["repos"].items()
    }
    return Config(
        state_dir=Path(data["state_dir"]),
        gcroots_dir=Path(data["gcroots_dir"]),
        access_log=Path(data["access_log"]),
        budget_bytes=int(data["budget_bytes"]),
        active_days=int(data["active_days"]),
        protect_hours=int(data["protect_hours"]),
        import_min_free_bytes=_top_int("import_min_free_bytes", data.get("import_min_free_bytes")),
        disk_alert_percent=_top_int("disk_alert_percent", data.get("disk_alert_percent"), 1, 99),
        system_roots=tuple(data.get("system_roots", [])),
        repos=repos,
    )
