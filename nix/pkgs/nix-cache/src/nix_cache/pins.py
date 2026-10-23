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

from nix_cache.manifest import STORE_PATH_RE

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


def _sweep(base: Path) -> None:
    """Remove stale temp dirs left by a crashed pin() or delete_pin()."""
    for e in base.iterdir():
        if e.name.startswith(".") and (e.name.endswith(".tmp") or e.name.endswith(".del")):
            if e.is_dir() and not e.is_symlink():
                shutil.rmtree(e, ignore_errors=True)
            elif e.name != ".latest.tmp":
                continue
            else:
                e.unlink()


def pin(pins_dir: Path, ns: Namespace, roots, now: int) -> Pin:
    _check(ns)
    roots = sorted(set(roots))
    for root in roots:
        if not isinstance(root, str) or not STORE_PATH_RE.fullmatch(root):
            raise ValueError(f"not a store path: {root!r}")
    base = ns.dir(pins_dir)
    base.mkdir(parents=True, exist_ok=True)
    _sweep(base)
    stamp = now
    while (base / str(stamp)).exists():
        stamp += 1
    tmp = base / f".{stamp}.tmp"
    tmp.mkdir()
    try:
        for root in roots:
            os.symlink(root, tmp / Path(root).name)
        final = base / str(stamp)
        os.rename(tmp, final)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    _set_latest(base, stamp)
    return Pin(ns, stamp, final, tuple(roots))


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


def _stamps(base: Path) -> list[int]:
    return [int(e.name) for e in _subdirs(base) if e.name.isdigit()]


def latest_stamps(pins_dir: Path) -> dict[Namespace, int]:
    result: dict[Namespace, int] = {}
    for repo in _subdirs(pins_dir):
        for set_ in _subdirs(repo):
            for arch in _subdirs(set_):
                ns = Namespace(repo.name, set_.name, arch.name)
                link = arch / "latest"
                if link.is_symlink():
                    target = os.readlink(link)
                    if target.isdigit() and (arch / target).is_dir():
                        result[ns] = int(target)
                        continue
                stamps = _stamps(arch)
                if stamps:
                    result[ns] = max(stamps)
    return result


def delete_pin(pins_dir: Path, p: Pin) -> None:
    base = p.namespace.dir(pins_dir)
    latest = base / "latest"
    others = [s for s in _stamps(base) if s != p.stamp]
    if others:
        _set_latest(base, max(others))
    elif latest.is_symlink():
        latest.unlink()
    doomed = base / f".{p.stamp}.del"
    if doomed.exists():
        shutil.rmtree(doomed)
    os.rename(p.path, doomed)
    shutil.rmtree(doomed)
    _sweep(base)
    d = base
    while d != pins_dir and d.is_dir() and not any(d.iterdir()):
        d.rmdir()
        d = d.parent
