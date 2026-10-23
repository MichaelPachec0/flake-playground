"""GC-root layout for imported bundles.

pins/<repo>/<set>/<arch>/<epoch>/<store basename> -> store path   (one dir per import)
pins/<repo>/<set>/<arch>/latest -> <epoch>                          (relative symlink)

Nix's GC scans directories under its gcroots dir recursively, so every
symlink inside a pin directory is a root. `latest` points at a directory,
which the GC does not follow; it only tells humans and the pruner which pin
is current.
"""

from __future__ import annotations

import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
ARCH_RE = re.compile(r"[a-z0-9_]+-[a-z]+")


@dataclass(frozen=True, order=True)
class Namespace:
    repo: str
    set: str
    arch: str

    def __str__(self) -> str:
        return f"{self.repo}/{self.set}/{self.arch}"

    def dir(self, pins_dir: Path) -> Path:
        return pins_dir / self.repo / self.set / self.arch


@dataclass(frozen=True)
class Pin:
    namespace: Namespace
    stamp: int
    path: Path
    targets: tuple[str, ...]


def _check(ns: Namespace) -> None:
    if not (
        NAME_RE.fullmatch(ns.repo)
        and NAME_RE.fullmatch(ns.set)
        and ARCH_RE.fullmatch(ns.arch)
    ):
        raise ValueError(f"invalid namespace {ns}")


def _set_latest(base: Path, stamp: int) -> None:
    tmp = base / ".latest.tmp"
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    os.symlink(str(stamp), tmp)
    os.replace(tmp, base / "latest")


def pin(pins_dir: Path, ns: Namespace, roots, now: int) -> Pin:
    _check(ns)
    base = ns.dir(pins_dir)
    base.mkdir(parents=True, exist_ok=True)
    stamp = now
    while (base / str(stamp)).exists():
        stamp += 1
    tmp = base / f".{stamp}.tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir()
    for root in roots:
        os.symlink(root, tmp / Path(root).name)
    final = base / str(stamp)
    os.rename(tmp, final)
    _set_latest(base, stamp)
    return Pin(ns, stamp, final, tuple(sorted(roots)))


def _subdirs(path: Path) -> list[Path]:
    if not path.is_dir():
        return []
    return sorted(p for p in path.iterdir() if p.is_dir() and not p.is_symlink())


def list_pins(pins_dir: Path) -> list[Pin]:
    pins: list[Pin] = []
    for repo in _subdirs(pins_dir):
        for set_ in _subdirs(repo):
            for arch in _subdirs(set_):
                ns = Namespace(repo.name, set_.name, arch.name)
                for entry in _subdirs(arch):
                    if not entry.name.isdigit():
                        continue
                    targets = tuple(
                        sorted(os.readlink(l) for l in entry.iterdir() if l.is_symlink())
                    )
                    pins.append(Pin(ns, int(entry.name), entry, targets))
    return sorted(pins, key=lambda p: (p.namespace, p.stamp))


def latest_stamps(pins_dir: Path) -> dict[Namespace, int]:
    result: dict[Namespace, int] = {}
    for repo in _subdirs(pins_dir):
        for set_ in _subdirs(repo):
            for arch in _subdirs(set_):
                link = arch / "latest"
                if link.is_symlink() and os.readlink(link).isdigit():
                    result[Namespace(repo.name, set_.name, arch.name)] = int(os.readlink(link))
    return result


def delete_pin(pins_dir: Path, p: Pin) -> None:
    shutil.rmtree(p.path)
    base = p.namespace.dir(pins_dir)
    latest = base / "latest"
    if latest.is_symlink() and not (base / os.readlink(latest)).is_dir():
        remaining = [int(e.name) for e in _subdirs(base) if e.name.isdigit()]
        if remaining:
            _set_latest(base, max(remaining))
        else:
            latest.unlink()
    d = base
    while d != pins_dir and d.is_dir() and not any(d.iterdir()):
        d.rmdir()
        d = d.parent
