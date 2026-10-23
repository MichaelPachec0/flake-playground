"""nix-cache-bundle: package what CI built, and the caches lack, into an upload bundle.

Runs on the CI runner after the build. Output is a file:// binary-cache dir
(narinfos + zstd NARs) plus manifest.json; the push job signs it and
streams it to the cache host.
"""

from __future__ import annotations

import argparse
import http.client
import json
import netrc
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import (
    HTTPBasicAuthHandler,
    HTTPPasswordMgrWithPriorAuth,
    OpenerDirector,
    Request,
    build_opener,
)

from . import nixcli
from .graph import store_hash
from .manifest import STORE_PATH_RE, Manifest, render_manifest
from .nixcli import NixError

DEFAULT_UPSTREAMS = ("https://cache.nixos.org",)
# Waits between narinfo probe attempts on 429, 5xx or a connection error.
RETRY_DELAYS = (1.0, 3.0, 9.0)
RETRY_STATUS = frozenset({429, 500, 502, 503, 504})


class BundleToolError(Exception):
    """The bundle cannot be produced (nothing to pin, dirty output dir, ...)."""


class ProbeError(Exception):
    """A cache answered a narinfo probe with neither 200 nor 404, even after retries."""


class CredentialsError(Exception):
    """The --netrc file is missing, unreadable or malformed."""


def _netrc_auth(netrc_file: Path, host: str) -> tuple[str, str, str] | None:
    """Look up host in netrc_file; errors never carry the file's contents.

    NetrcParseError quotes the offending token, which may be the password,
    so only its line number survives into the message (and CI logs).
    """
    try:
        return netrc.netrc(str(netrc_file)).authenticators(host)
    except netrc.NetrcParseError as e:
        raise CredentialsError(f"netrc {netrc_file} is malformed near line {e.lineno}") from None
    except OSError as e:
        raise CredentialsError(f"cannot read netrc {netrc_file}: {e.strerror or type(e).__name__}") from None


def own_opener(netrc_file: Path | None, base_url: str) -> OpenerDirector:
    if netrc_file is None:
        return build_opener()
    auth = _netrc_auth(netrc_file, urlparse(base_url).hostname or "")
    if auth is None:
        return build_opener()
    login, _, password = auth
    mgr = HTTPPasswordMgrWithPriorAuth()
    mgr.add_password(None, base_url, login, password or "", is_authenticated=True)
    return build_opener(HTTPBasicAuthHandler(mgr))


def fetch_narinfo(opener: OpenerDirector, base_url: str, h: str, timeout: float = 20.0) -> str | None:
    """Return the narinfo body, or None when the cache answers 404.

    Only a 404 means "absent". A busy or broken cache (429, 5xx, connection
    error) is retried and then raises ProbeError: reading it as "absent"
    would drop cached roots from the pin and re-upload cached dependencies.
    """
    url = f"{base_url.rstrip('/')}/{h}.narinfo"
    req = Request(url, headers={"User-Agent": "nix-cache-bundle"})
    last = ""
    for attempt in range(len(RETRY_DELAYS) + 1):
        if attempt:
            time.sleep(RETRY_DELAYS[attempt - 1])
        try:
            with opener.open(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8", "replace")
        except HTTPError as e:
            if e.code == 404:
                return None
            if e.code not in RETRY_STATUS:
                raise ProbeError(f"{url}: HTTP {e.code}") from e
            last = f"HTTP {e.code}"
        except (URLError, TimeoutError, OSError, http.client.HTTPException) as e:
            # HTTPException: a malformed status line or a body cut short
            # (BadStatusLine, IncompleteRead), which urllib does not wrap.
            last = f"{type(e).__name__}: {e}"
    raise ProbeError(f"{url}: {last} after {len(RETRY_DELAYS) + 1} attempts")


def has_narinfo(opener: OpenerDirector, base_url: str, h: str, timeout: float = 20.0) -> bool:
    return fetch_narinfo(opener, base_url, h, timeout) is not None


def fetch_present(opener: OpenerDirector, base_url: str, paths, jobs: int) -> dict[str, str]:
    """Narinfo bodies of the paths the cache has (path -> body)."""
    paths = list(paths)
    if not paths:
        return {}
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        bodies = list(pool.map(lambda p: fetch_narinfo(opener, base_url, store_hash(p)), paths))
    return {p: b for p, b in zip(paths, bodies) if b is not None}


def present_on(opener: OpenerDirector, base_url: str, paths, jobs: int) -> set[str]:
    return set(fetch_present(opener, base_url, paths, jobs))


def seed_narinfo(path: str, info: dict) -> str:
    """A minimal narinfo for a path that stays out of the bundle, from local path-info."""
    return "\n".join([
        f"StorePath: {path}",
        f"URL: nar/{store_hash(path)}.nar",
        "Compression: none",
        f"NarHash: {info['narHash']}",
        f"NarSize: {info['narSize']}",
        "References: " + " ".join(Path(r).name for r in info.get("references", [])),
    ]) + "\n"


def copy_missing(out: Path, missing: list[str], closure: dict[str, dict], served: dict[str, str]) -> None:
    """`nix copy --no-recursive` the missing paths into the file:// dir OUT.

    Nix refuses to add a path to a binary cache unless each of its references
    is already valid there, and the bundle leaves out on purpose every
    reference a cache already serves. So seed OUT with a narinfo for each
    such reference (the body the cache answered the presence GET with, else
    one built from local path-info), copy, then delete the seeds: the bundle
    carries only the missing paths and the importer substitutes the rest.
    """
    wanted = set(missing)
    refs = sorted({r for p in missing for r in closure[p]["references"]} - wanted)
    seeds: list[Path] = []
    try:
        for r in refs:
            body = served.get(r)
            if body is None or f"StorePath: {r}" not in body.splitlines():
                body = seed_narinfo(r, closure[r])
            seed = out / f"{store_hash(r)}.narinfo"
            seed.write_text(body)
            seeds.append(seed)
        nixcli.nix(
            "copy", "--no-recursive",
            "--to", f"file://{out}?compression=zstd&parallel-compression=true",
            "--stdin",
            stdin="".join(f"{p}\n" for p in missing),
        )
    finally:
        for seed in seeds:
            seed.unlink(missing_ok=True)


def check_roots(roots: object) -> list[str]:
    """Roots must be a JSON list of plain store paths (no options, no newlines)."""
    if not isinstance(roots, list) or not all(isinstance(r, str) and STORE_PATH_RE.fullmatch(r) for r in roots):
        raise BundleToolError("roots must be a JSON list of store paths")
    return roots


def load_roots(path: Path) -> list[str]:
    try:
        data = json.loads(path.read_text())
    except OSError as e:
        raise BundleToolError(f"cannot read roots file {path}: {e.strerror or type(e).__name__}") from None
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        raise BundleToolError(f"roots file {path} is not valid JSON: {e}") from None
    return check_roots(data)


def make_bundle(
    *,
    roots,
    set_: str,
    arch: str,
    out: Path,
    upstreams,
    own_url: str | None,
    netrc_file: Path | None,
    run_id: str,
    commit: str,
    jobs: int = 8,
) -> Manifest:
    roots = check_roots(list(roots) if isinstance(roots, (tuple, set, frozenset)) else roots)
    if jobs < 1:
        raise BundleToolError(f"jobs must be at least 1, not {jobs}")
    if out.exists() and any(out.iterdir()):
        raise BundleToolError(f"{out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    roots = sorted(set(roots))
    own = own_opener(netrc_file, own_url) if own_url else None
    on_own = present_on(own, own_url, roots, jobs) if own else set()
    not_local = nixcli.invalid_paths([r for r in roots if r not in on_own])
    for r in sorted(not_local):
        print(f"nix-cache-bundle: skipping {r}: not built here and not on the cache", file=sys.stderr)
    upload_roots = [r for r in roots if r not in on_own and r not in not_local]
    pinned = sorted(on_own | set(upload_roots))
    if not pinned:
        raise BundleToolError("no root is built locally or present on the cache")

    closure = nixcli.path_info(upload_roots, recursive=True) if upload_roots else {}
    remaining = set(closure)
    served: dict[str, str] = {}  # narinfo bodies of closure paths some cache already has
    if own:
        served.update(fetch_present(own, own_url, sorted(remaining), jobs))
        remaining -= served.keys()
    plain = build_opener()
    for upstream in upstreams:
        found = fetch_present(plain, upstream, sorted(remaining), jobs)
        served.update(found)
        remaining -= found.keys()
    missing = sorted(remaining)
    if missing:
        copy_missing(out, missing, closure, served)
    info = out / "nix-cache-info"
    if not info.exists():
        info.write_text("StoreDir: /nix/store\n")
    for extra in ("log", "realisations"):
        d = out / extra
        if d.is_dir():
            if any(d.iterdir()):
                raise BundleToolError(f"{d} is not empty; the importer only accepts narinfos and NARs")
            d.rmdir()
    manifest = Manifest(set=set_, arch=arch, roots=tuple(pinned), paths=tuple(missing), run_id=run_id, commit=commit)
    (out / "manifest.json").write_text(render_manifest(manifest))
    print(
        f"nix-cache-bundle: {len(pinned)} roots ({len(on_own)} already cached), {len(missing)} paths to upload",
        file=sys.stderr,
    )
    return manifest


def _positive_int(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not an integer") from None
    if value < 1:
        raise argparse.ArgumentTypeError(f"must be at least 1, not {value}")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nix-cache-bundle", description="Bundle built outputs for the nix cache.")
    parser.add_argument("--roots-json", type=Path, required=True, help="JSON list of output paths (nix eval --json)")
    parser.add_argument("--set", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--upstream", action="append", help="upstream cache URL; default https://cache.nixos.org")
    parser.add_argument("--no-upstream", action="store_true", help="do not consult any upstream cache")
    parser.add_argument("--own-cache", help="URL of the self-hosted cache")
    parser.add_argument("--netrc", type=Path, help="netrc with the read token for --own-cache")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--commit", default="")
    # 8 per process: parallel CI jobs share one read-token user, and nginx
    # allows 32 connections per user (excess ones get 503).
    parser.add_argument("--jobs", type=_positive_int, default=8)
    args = parser.parse_args(argv)
    upstreams = [] if args.no_upstream else (args.upstream or list(DEFAULT_UPSTREAMS))
    try:
        make_bundle(
            roots=load_roots(args.roots_json),
            set_=args.set,
            arch=args.arch,
            out=args.out,
            upstreams=upstreams,
            own_url=args.own_cache,
            netrc_file=args.netrc,
            run_id=args.run_id,
            commit=args.commit,
            jobs=args.jobs,
        )
    except BundleToolError as e:
        print(f"nix-cache-bundle: {e}", file=sys.stderr)
        return 2
    except (NixError, ProbeError, CredentialsError) as e:
        print(f"nix-cache-bundle: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
