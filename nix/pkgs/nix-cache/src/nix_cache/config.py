"""The JSON config the NixOS module writes for the importer and pruner."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

KEY_RE = re.compile(r"[A-Za-z0-9._-]+:[A-Za-z0-9+/]+={0,2}")


def _keys(name: str, keys: object) -> tuple[str, ...]:
    if not isinstance(keys, list) or not keys:
        raise ValueError(f"repo {name!r}: trusted_keys must be a non-empty list")
    for key in keys:
        if not isinstance(key, str) or not KEY_RE.fullmatch(key):
            raise ValueError(f"repo {name!r}: invalid trusted key {key!r}")
    return tuple(keys)


@dataclass(frozen=True)
class RepoConfig:
    name: str
    drop_dir: Path
    trusted_keys: tuple[str, ...]
    max_bundle_bytes: int
    max_unpacked_bytes: int
    max_pending: int
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
        system_roots=tuple(data.get("system_roots", [])),
        repos=repos,
    )
