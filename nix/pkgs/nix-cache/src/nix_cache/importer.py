"""cache-importer: turn uploaded bundles into store paths plus GC-root pins.

Runs as the untrusted `nix-cache` user (no network, no sudo). Every store
write goes through the root nix-daemon, which re-checks signatures, so this
code cannot weaken trust; it only adds a per-repo key binding on top: a
repo's drop directory only ever imports paths signed by that repo's keys.
Roots are never substituted: each is either a bundled (signed) path or
already valid on the host. Upstream signatures are valid too, so
substituting a root would let a bundle without paths (which needs no repo
signature) make the host download and pin arbitrary upstream closures.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
import time
from pathlib import Path

from . import nixcli
from .alert import queue_alert
from .config import Config, RepoConfig, load_config
from .db import load_hits, open_db
from .extract import BundleError, check_nar_size, extract_bundle
from .graph import build_graph, system_closure
from .lock import locked
from .manifest import ManifestError, parse_manifest
from .narinfo import NarInfo, NarInfoError, parse_narinfo
from .nixcli import NixError
from .pins import Namespace, Pin, latest_stamps, list_pins, pin
from .retention import Policy, protected_bytes

BUNDLE_RE = re.compile(r"[0-9]+-[0-9]+\.tar\.zst")
FAILED_RETENTION_SECONDS = 7 * 86400
REJECT_ERRORS = (BundleError, ManifestError, NarInfoError, NixError, ValueError)
STORE_FS = "/nix/store"


def pending_bundles(incoming: Path) -> list[Path]:
    found = [p for p in incoming.iterdir() if BUNDLE_RE.fullmatch(p.name)]
    return sorted(found, key=lambda p: tuple(int(x) for x in p.name.split(".")[0].split("-")))


def load_narinfos(d: Path) -> dict[str, NarInfo]:
    infos: dict[str, NarInfo] = {}
    for f in sorted(d.glob("*.narinfo")):
        info = parse_narinfo(f.read_text())
        if f.name != Path(info.store_path).name[:32] + ".narinfo":
            raise BundleError(f"{f.name} describes {info.store_path}")
        if not (d / info.url).is_file():
            raise BundleError(f"{f.name} points at missing {info.url}")
        infos[info.store_path] = info
    return infos


def check_key_names(infos: dict[str, NarInfo], trusted_keys) -> None:
    """Cheap half of the key binding: every bundled narinfo carries a signature
    whose key NAME is one of the repo's. No nix call, so it runs first and an
    unsigned bundle never makes the importer read the store graph."""
    names = {k.split(":", 1)[0] for k in trusted_keys}
    unsigned = sorted(p for p, i in infos.items() if not (i.key_names & names))
    if unsigned:
        raise BundleError(
            f"{len(unsigned)} path(s) carry no signature from {', '.join(sorted(names))};"
            f" first: {unsigned[0]}"
        )


def verify_key_binding(infos: dict[str, NarInfo], trusted_keys, bundle_url: str) -> None:
    """Expensive half: nix verifies the signatures and contents themselves."""
    if infos:
        try:
            nixcli.verify_sigs(bundle_url, sorted(infos), trusted_keys)
        except NixError as e:
            raise BundleError(f"signature or content check failed: {e}") from e


class SizeGuard:
    """Rejects an import that would push protected paths over the budget or
    leave less than the floor free on /nix/store, before anything is fetched.

    Retention never evicts protected paths (latest pin of each active
    namespace, fresh registrations and narinfo hits), even over the budget,
    so without this check repeated uploads, or a small signed path whose
    references pull in huge upstream closures, could fill the disk.

    Protected bytes are computed once per bundle and reused: nothing changes
    the store between the checks, since the importer holds the shared lock.
    """

    def __init__(self, cfg: Config, now: int) -> None:
        self._cfg = cfg
        self._now = now
        self._protected: int | None = None

    def _protected_bytes(self) -> int:
        if self._protected is None:
            cfg = self._cfg
            graph = build_graph(nixcli.path_info(all_paths=True))
            if not graph:
                # As in the pruner: an empty store listing means the query is
                # broken, and protected bytes would wrongly read as 0.
                raise BundleError("nix path-info --all returned no store paths; refusing to import")
            conn = open_db(cfg.db)
            try:
                hits = load_hits(conn)
            finally:
                conn.close()
            self._protected = protected_bytes(
                graph,
                list_pins(cfg.pins_dir),
                latest_stamps(cfg.pins_dir),
                hits,
                system_closure(graph, cfg.system_roots),
                Policy.from_config(cfg),
                self._now,
            )
        return self._protected

    def check(self, new_bytes: int) -> None:
        if new_bytes == 0:
            # Re-pinning paths the host already has never fails on budget or space.
            return
        cfg = self._cfg
        protected = self._protected_bytes()
        if protected + new_bytes > cfg.budget_bytes:
            raise BundleError(
                f"bundle would add {new_bytes} bytes to {protected} protected bytes,"
                f" over the budget of {cfg.budget_bytes}"
            )
        try:
            st = os.statvfs(STORE_FS)
        except OSError as e:
            raise BundleError(f"cannot read free space on {STORE_FS}: {e}") from e
        free = st.f_bavail * st.f_frsize
        if free - new_bytes < cfg.import_min_free_bytes:
            raise BundleError(
                f"bundle would leave {free - new_bytes} bytes free on {STORE_FS},"
                f" below the floor of {cfg.import_min_free_bytes}"
            )


def estimate_fetch(missing: set[str]) -> int:
    try:
        return nixcli.fetch_estimate(missing) if missing else 0
    except NixError as e:
        raise BundleError(
            f"cannot estimate the download of {len(missing)} path(s) outside the bundle: {e}"
        ) from e


def import_bundle(bundle: Path, repo: RepoConfig, cfg: Config, now: int) -> Pin:
    size = bundle.stat().st_size
    if size > repo.max_bundle_bytes:
        raise BundleError(f"bundle is {size} bytes, cap is {repo.max_bundle_bytes}")
    cfg.work_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cfg.work_dir) as tmp:
        d = Path(tmp)
        extract_bundle(bundle, d, repo.max_unpacked_bytes)
        if not (d / "manifest.json").is_file():
            raise BundleError("bundle has no manifest.json")
        manifest = parse_manifest((d / "manifest.json").read_text())
        # Checked before any signature, size or store check. A bundle without
        # paths needs no signature and can only re-pin roots the host already
        # has (see the roots check below); these two caps limit an upload-key
        # holder to the repo's own namespaces and a bounded number of roots
        # per bundle.
        if manifest.set not in repo.allowed_sets:
            raise BundleError(
                f"set {manifest.set!r} is not allowed for {repo.name}"
                f" (allowed: {', '.join(repo.allowed_sets)})"
            )
        if len(manifest.roots) > repo.max_roots:
            raise BundleError(f"bundle names {len(manifest.roots)} roots, cap is {repo.max_roots}")
        infos = load_narinfos(d)
        if set(manifest.paths) != set(infos):
            raise BundleError("manifest paths do not match the narinfos in the bundle")
        url = f"file://{d}"
        # Size guard on the claimed NarSizes alone, before anything is
        # verified or decompressed: a signed path with a genuinely huge NAR
        # is turned away without unpacking it.
        check_key_names(infos, repo.trusted_keys)
        guard = SizeGuard(cfg, now)
        bundled_new = sum(infos[p].nar_size for p in nixcli.invalid_paths(infos))
        guard.check(bundled_new)
        verify_key_binding(infos, repo.trusted_keys, url)
        # NarSize feeds the size guards below; prove it before trusting it.
        for info in infos.values():
            check_nar_size(d / info.url, info.compression, info.nar_size)
        # Every root is a bundled (signed) path or already valid on the host;
        # roots are never substituted. Checked before any realise or copy.
        # Roots served by the own cache count as valid here: if they were
        # collected in between, this rejects and the next CI run ships them.
        outside = {r for r in manifest.roots if r not in infos}
        absent = nixcli.invalid_paths(outside)
        if absent:
            raise BundleError(
                f"{len(absent)} root(s) are neither in the bundle nor on this host;"
                f" first: {sorted(absent)[0]}"
            )
        # References of bundled (signed) paths that CI left out (present on
        # cache.nixos.org or already here) must be valid before the copy.
        external = {ref for i in infos.values() for ref in i.references} - infos.keys()
        missing = nixcli.invalid_paths(external)
        # Full guard: proven bundled sizes plus what the missing references fetch.
        guard.check(bundled_new + estimate_fetch(missing))
        if missing:
            try:
                nixcli.realise(missing)
            except NixError as e:
                raise BundleError(
                    f"{len(missing)} path(s) outside the bundle are neither on this host nor"
                    f" substitutable: {e}"
                ) from e
        if infos:
            nixcli.copy_no_recursive(url, sorted(infos))
        still = nixcli.invalid_paths(manifest.roots)
        if still:
            raise BundleError(f"roots not valid after import; first: {sorted(still)[0]}")
        return pin(cfg.pins_dir, Namespace(repo.name, manifest.set, manifest.arch), manifest.roots, now)


def reject(bundle: Path, repo: RepoConfig, reason: str, cfg: Config) -> None:
    # The .reason file and the alert come BEFORE the bundle leaves incoming/:
    # anything that waits for an empty incoming/ (the VM test, an operator)
    # then always finds the reason next to the moved bundle.
    repo.failed.mkdir(parents=True, exist_ok=True)
    (repo.failed / (bundle.name + ".reason")).write_text(reason + "\n")
    queue_alert(cfg.spool, f"nix-cache: rejected bundle from {repo.name}", f"{bundle.name}: {reason}")
    os.replace(bundle, repo.failed / bundle.name)
    print(f"rejected {bundle.name}: {reason}", file=sys.stderr)


def prune_failed(repo: RepoConfig, now: int) -> None:
    if not repo.failed.is_dir():
        return
    for entry in repo.failed.iterdir():
        if entry.is_file() and now - entry.stat().st_mtime > FAILED_RETENTION_SECONDS:
            entry.unlink()


def run(cfg: Config, repo_name: str, now: int | None = None) -> int:
    repo = cfg.repos[repo_name]
    with locked(cfg.lock_file):
        now = now if now is not None else int(time.time())
        prune_failed(repo, now)
        bundles = pending_bundles(repo.incoming)
        for extra in bundles[repo.max_pending :]:
            reject(extra, repo, f"more than {repo.max_pending} bundles pending", cfg)
        for bundle in bundles[: repo.max_pending]:
            try:
                p = import_bundle(bundle, repo, cfg, now)
            except REJECT_ERRORS as e:
                reject(bundle, repo, str(e), cfg)
                continue
            except Exception as e:
                # Anything else (ENOSPC, EIO, a bug) also moves the bundle out
                # of incoming/: left there, the path unit would restart this
                # run on it over and over. If reject() itself fails, the run
                # crashes and the unit's start limit and OnFailure take over.
                reject(bundle, repo, f"internal error: {type(e).__name__}: {e}", cfg)
                continue
            bundle.unlink()
            print(f"imported {bundle.name} -> {p.namespace} @{p.stamp} ({len(p.targets)} roots)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cache-importer", description="Import uploaded nix-cache bundles.")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args(argv)
    cfg = load_config(args.config)
    if args.repo not in cfg.repos:
        print(f"cache-importer: unknown repo {args.repo!r}", file=sys.stderr)
        return 2
    return run(cfg, args.repo)


if __name__ == "__main__":
    sys.exit(main())
