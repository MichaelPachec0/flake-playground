"""Every nix / nix-store invocation goes through here.

Tests point NIX_CACHE_NIX / NIX_CACHE_NIX_STORE at fakes. Paths are passed
on stdin (or in chunks) so large closures never hit ARG_MAX.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from collections.abc import Iterable, Iterator

from .manifest import STORE_PATH_RE

NIX = os.environ.get("NIX_CACHE_NIX", "nix")
NIX_STORE = os.environ.get("NIX_CACHE_NIX_STORE", "nix-store")
FEATURES = ["--extra-experimental-features", "nix-command"]
STORE_DIR = "/nix/store"
CHUNK = 500


class NixError(RuntimeError):
    """A nix command exited non-zero."""


def _exec(argv: list[str], stdin: str | None = None) -> subprocess.CompletedProcess:
    proc = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    if proc.returncode != 0:
        shown = " ".join(argv[:4])
        raise NixError(f"{shown} ... failed ({proc.returncode}): {proc.stderr.strip()[-2000:]}")
    return proc


def _run(argv: list[str], stdin: str | None = None) -> str:
    return _exec(argv, stdin).stdout


def _run_stderr(argv: list[str]) -> str:
    """For commands that print their report on stderr (nix-store --dry-run)."""
    return _exec(argv).stderr


def _chunks(items: list[str]) -> Iterator[list[str]]:
    for i in range(0, len(items), CHUNK):
        yield items[i : i + CHUNK]


def _checked(paths: Iterable[str]) -> list[str]:
    """Reject anything that is not a plain store path (option or newline smuggling)."""
    result = list(paths)
    for p in result:
        if not isinstance(p, str) or not STORE_PATH_RE.fullmatch(p):
            raise NixError(f"refusing non-store path: {p!r}")
    return result


def _lines(paths: Iterable[str]) -> str:
    return "".join(f"{p}\n" for p in _checked(paths))


def nix(*args: str, stdin: str | None = None) -> str:
    return _run([NIX, *FEATURES, *args], stdin)


def invalid_paths(paths: Iterable[str]) -> set[str]:
    result: set[str] = set()
    for chunk in _chunks(sorted(set(_checked(paths)))):
        result.update(_run([NIX_STORE, "--check-validity", "--print-invalid", *chunk]).split())
    return result


def realise(paths: Iterable[str]) -> None:
    """Substitute store paths (they have no derivation here, so nothing is built)."""
    for chunk in _chunks(sorted(set(_checked(paths)))):
        _run([NIX_STORE, "--realise", *chunk])


# printMissing (libmain/shared.cc, Nix 2.34) with sizes from renderSize: one
# decimal and a binary unit, never below KiB ("0.1 KiB" for 100 bytes).
_SIZE = r"([0-9]+)\.([0-9]) ([KMGTPEZY])iB"
FETCH_SUMMARY_RE = re.compile(
    rf"(?:this path|these [0-9]+ paths) will be fetched \({_SIZE} download, {_SIZE} unpacked\):"
)
_UNIT_POWER = {u: i + 1 for i, u in enumerate("KMGTPEZY")}
# "warning: ..." lines (e.g. an ignored substituter) do not change the report.
_HARMLESS_RE = re.compile(r"warning: .*")


def _size_up(whole: str, tenth: str, unit: str) -> int:
    """Bytes of a renderSize value, rounded up: it may hide up to half a tenth."""
    tenths = int(whole) * 10 + int(tenth)
    scale = 1024 ** _UNIT_POWER[unit]
    return -(-(2 * tenths + 1) * scale // 20)


def _parse_dry_run(report: str) -> int:
    total = 0
    summaries = 0
    for line in report.splitlines():
        if not line.strip() or _HARMLESS_RE.fullmatch(line):
            continue
        if line.startswith("  ") and STORE_PATH_RE.fullmatch(line[2:]):
            continue
        m = FETCH_SUMMARY_RE.fullmatch(line)
        if m is None:
            # Builds, unknown paths and anything unexpected: fail closed.
            raise NixError(f"unexpected nix-store --dry-run output: {line[:300]!r}")
        total += _size_up(*m.group(4, 5, 6))
        summaries += 1
    if summaries == 0:
        # Callers pass only invalid paths: each one is fetched, built or
        # unknown, so a report without a summary went missing. Fail closed.
        raise NixError("nix-store --dry-run printed no fetch summary for paths that are not on this host")
    return total


def fetch_estimate(paths: Iterable[str]) -> int:
    """Bytes (NAR size, rounded up) the store would grow by if paths were realised.

    paths must all be invalid on the host (the importer's missing set): a
    chunk whose report has no "will be fetched" summary raises NixError.

    Goes through the daemon like realise, so it works without network access
    in this process. print-missing is forced on: with it off, nix-store
    prints nothing and the estimate would silently read as 0.
    """
    total = 0
    for chunk in _chunks(sorted(set(_checked(paths)))):
        report = _run_stderr([NIX_STORE, "--option", "print-missing", "true", "--realise", "--dry-run", *chunk])
        total += _parse_dry_run(report)
    return total


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
