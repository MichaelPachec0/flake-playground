"""Every nix / nix-store invocation goes through here.

Tests point NIX_CACHE_NIX / NIX_CACHE_NIX_STORE at fakes. Paths are passed
on stdin (or in chunks) so large closures never hit ARG_MAX.
"""

from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Iterable, Iterator

NIX = os.environ.get("NIX_CACHE_NIX", "nix")
NIX_STORE = os.environ.get("NIX_CACHE_NIX_STORE", "nix-store")
FEATURES = ["--extra-experimental-features", "nix-command"]
STORE_DIR = "/nix/store"
CHUNK = 500


class NixError(RuntimeError):
    """A nix command exited non-zero."""


def _run(argv: list[str], stdin: str | None = None) -> str:
    proc = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    if proc.returncode != 0:
        shown = " ".join(argv[:4])
        raise NixError(f"{shown} ... failed ({proc.returncode}): {proc.stderr.strip()[-2000:]}")
    return proc.stdout


def _chunks(items: list[str]) -> Iterator[list[str]]:
    for i in range(0, len(items), CHUNK):
        yield items[i : i + CHUNK]


def _lines(paths: Iterable[str]) -> str:
    return "".join(f"{p}\n" for p in paths)


def nix(*args: str, stdin: str | None = None) -> str:
    return _run([NIX, *FEATURES, *args], stdin)


def invalid_paths(paths: Iterable[str]) -> set[str]:
    result: set[str] = set()
    for chunk in _chunks(sorted(set(paths))):
        result.update(_run([NIX_STORE, "--check-validity", "--print-invalid", *chunk]).split())
    return result


def realise(paths: Iterable[str]) -> None:
    """Substitute store paths (they have no derivation here, so nothing is built)."""
    for chunk in _chunks(sorted(set(paths))):
        _run([NIX_STORE, "--realise", *chunk])


def _full(path: str) -> str:
    return path if path.startswith("/") else f"{STORE_DIR}/{path}"


def normalise_path_info(data: object) -> dict[str, dict]:
    """Accept both the list (older Nix) and the object (newer Nix) JSON shapes."""
    if isinstance(data, dict):
        entries = list(data.items())
    else:
        entries = [(e["path"], e) for e in data]  # type: ignore[union-attr]
    result: dict[str, dict] = {}
    for path, info in entries:
        if info is None:
            continue
        deriver = info.get("deriver")
        result[_full(path)] = {
            **info,
            "references": [_full(r) for r in info.get("references", [])],
            "deriver": _full(deriver) if deriver else None,
        }
    return result


def path_info(
    paths: Iterable[str] = (),
    *,
    recursive: bool = False,
    all_paths: bool = False,
    store: str | None = None,
) -> dict[str, dict]:
    # Bare --json is deprecated on Nix 2.34 (it will become an error); format 1
    # is the store-path-keyed object normalise_path_info already handles.
    args = ["path-info", "--json", "--json-format", "1"]
    if store:
        args += ["--store", store]
    stdin = None
    if all_paths:
        args.append("--all")
    else:
        if recursive:
            args.append("--recursive")
        args.append("--stdin")
        stdin = _lines(paths)
    return normalise_path_info(json.loads(nix(*args, stdin=stdin)))


def verify_sigs(store_url: str, paths: Iterable[str], trusted_keys: Iterable[str]) -> None:
    """Check NAR contents and require one valid signature from trusted_keys only."""
    nix(
        "store", "verify",
        "--store", store_url,
        "--option", "trusted-public-keys", " ".join(trusted_keys),
        "--sigs-needed", "1",
        "--stdin",
        stdin=_lines(paths),
    )


def copy_no_recursive(src_url: str, paths: Iterable[str], dest: str = "daemon") -> None:
    nix("copy", "--no-recursive", "--from", src_url, "--to", dest, "--stdin", stdin=_lines(paths))
