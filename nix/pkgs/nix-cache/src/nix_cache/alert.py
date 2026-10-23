"""Alert spool.

The importer and pruner run with PrivateNetwork=true, so they only queue
alerts as JSON files. nix-cache-alert.service (triggered by a path unit,
network allowed) delivers them by running COMMAND TITLE with the body on
stdin. Failed deliveries move to a deferred dir outside the spool (so the
path unit does not re-trigger in a loop); the hourly pruner requeues them.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path


def queue_alert(spool: Path, title: str, body: str) -> Path:
    spool.mkdir(parents=True, exist_ok=True)
    staging = spool.with_name(spool.name + ".tmp")
    staging.mkdir(parents=True, exist_ok=True)
    name = f"{time.time_ns()}-{uuid.uuid4().hex[:8]}.json"
    tmp = staging / name
    tmp.write_text(json.dumps({"title": title, "body": body}))
    final = spool / name
    os.replace(tmp, final)
    return final


def flush(spool: Path, deferred: Path, command: str) -> int:
    if not spool.is_dir():
        return 0
    failures = 0
    for item in sorted(p for p in spool.iterdir() if p.suffix == ".json"):
        try:
            data = json.loads(item.read_text())
            title, body = str(data["title"]), str(data["body"])
        except (OSError, ValueError, KeyError, TypeError):
            item.unlink(missing_ok=True)
            continue
        try:
            proc = subprocess.run(
                [command, title], input=body, text=True, capture_output=True, timeout=60
            )
            ok = proc.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            ok = False
        if ok:
            item.unlink()
        else:
            deferred.mkdir(parents=True, exist_ok=True)
            os.replace(item, deferred / item.name)
            failures += 1
    return 1 if failures else 0


def requeue(deferred: Path, spool: Path) -> None:
    if not deferred.is_dir():
        return
    spool.mkdir(parents=True, exist_ok=True)
    for item in deferred.iterdir():
        if item.suffix == ".json":
            os.replace(item, spool / item.name)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nix-cache-alert", description="Deliver queued nix-cache alerts.")
    parser.add_argument("--spool", type=Path, required=True)
    parser.add_argument("--deferred", type=Path, required=True)
    parser.add_argument("--command", required=True, help="executable run as COMMAND TITLE, body on stdin")
    args = parser.parse_args(argv)
    return flush(args.spool, args.deferred, args.command)


if __name__ == "__main__":
    sys.exit(main())
