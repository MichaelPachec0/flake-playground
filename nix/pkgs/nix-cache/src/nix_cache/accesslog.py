"""Ingest nginx's JSON access log for the cache vhost into the stats DB.

Every field is attacker-influenced (URI, $remote_user), so parsing is
defensive: a bad line is skipped, never fatal, and user names are restricted
to a safe charset and length before they reach the DB.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

HASH = "[0-9a-df-np-sv-z]{32}"
# Whole-string matches (re.fullmatch), so a newline smuggled into the URI never matches.
NARINFO_RE = re.compile(rf"/({HASH})\.narinfo")
NAR_RE = re.compile(rf"/nar/[^?]*\?(?:[^#&]*&)*hash=({HASH})(?:&[^#]*)?")
USER_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")
MAX_LINE = 65536


@dataclass(frozen=True)
class Entry:
    t: int
    user: str
    uri: str
    status: int


def parse_line(line: bytes) -> Entry | None:
    try:
        d = json.loads(line)
        if not isinstance(d, dict):
            return None
        t, uri, status, user = d["t"], d["uri"], d["s"], d.get("u")
        if not isinstance(t, str) or not isinstance(uri, str):
            return None
        if isinstance(status, bool) or not isinstance(status, (int, str)):
            return None
        when = datetime.fromisoformat(t)
        if when.tzinfo is None:
            return None
        if not (isinstance(user, str) and USER_RE.fullmatch(user)):
            user = ""
        ts = int(when.timestamp())
        if ts <= 0:
            return None
        return Entry(t=ts, user=user, uri=uri, status=int(status))
    except (ValueError, KeyError, TypeError, OverflowError, OSError, RecursionError):
        return None


def _hit(conn: sqlite3.Connection, column: str, counter: str, h: str, t: int) -> None:
    conn.execute(
        f"INSERT INTO paths(hash, {column}, {counter}) VALUES (?, ?, 1) "
        f"ON CONFLICT(hash) DO UPDATE SET "
        f"{column} = max(coalesce({column}, 0), excluded.{column}), {counter} = {counter} + 1",
        (h, t),
    )


def apply(conn: sqlite3.Connection, e: Entry) -> None:
    if e.status in (200, 206):
        m = NARINFO_RE.fullmatch(e.uri)
        if m and e.status == 200:
            _hit(conn, "last_narinfo_hit", "narinfo_hits", m.group(1), e.t)
        m = NAR_RE.fullmatch(e.uri)
        if m:
            _hit(conn, "last_nar_hit", "nar_hits", m.group(1), e.t)
        if e.user:
            conn.execute(
                "INSERT INTO users(name, last_ok) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET "
                "last_ok = max(coalesce(last_ok, 0), excluded.last_ok), recent_fails = 0",
                (e.user, e.t),
            )
    elif e.status == 401 and e.user:
        # UPDATE only: rows are created by successful requests, so anonymous
        # 401s with random user names cannot grow the table.
        conn.execute("UPDATE users SET recent_fails = recent_fails + 1 WHERE name = ?", (e.user,))


def _read(conn: sqlite3.Connection, path: Path, offset: int) -> int:
    with open(path, "rb") as f:
        return _read_file(conn, f, offset)


def _read_file(conn: sqlite3.Connection, f, offset: int) -> int:
    """Consume complete lines from offset; return the new offset.

    Lines longer than MAX_LINE are skipped without being held in memory.
    An incomplete trailing line is left for the next run.
    """
    f.seek(offset)
    while True:
        start = offset
        line = f.readline(MAX_LINE)
        if not line:
            break
        size = len(line)
        oversize = False
        while not line.endswith(b"\n"):
            if size < MAX_LINE and not oversize:
                return start  # incomplete line at EOF
            oversize = True
            chunk = f.readline(MAX_LINE)
            if not chunk:
                return start  # oversize and unterminated: retry later
            size += len(chunk)
            line = chunk
        offset = start + size
        if not oversize:
            entry = parse_line(line)
            if entry is not None:
                apply(conn, entry)
    return offset


def ingest(conn: sqlite3.Connection, log: Path) -> None:
    try:
        f = open(log, "rb")
    except FileNotFoundError:
        return
    # Inode and size come from the open descriptor, so a rotation between a
    # stat and the open cannot pair the old inode with the new file.
    with f:
        st = os.fstat(f.fileno())
        try:
            row = conn.execute("SELECT inode, offset FROM ingest WHERE log = ?", (str(log),)).fetchone()
            offset = 0
            if row is not None:
                inode, saved = row
                if inode == st.st_ino:
                    offset = saved if saved <= st.st_size else 0
                else:
                    rotated = log.with_name(log.name + ".1")
                    try:
                        if rotated.stat().st_ino == inode:
                            _read(conn, rotated, saved)
                    except FileNotFoundError:
                        pass
            new_offset = _read_file(conn, f, offset)
            conn.execute(
                "INSERT INTO ingest(log, inode, offset) VALUES (?, ?, ?) ON CONFLICT(log) DO UPDATE SET "
                "inode = excluded.inode, offset = excluded.offset",
                (str(log), st.st_ino, new_offset),
            )
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
