"""SQLite state of the pruner: path access stats, token users, log position, notices.

Schema is part of the Rust-port contract; only add columns with defaults.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS paths (
  hash TEXT PRIMARY KEY,
  last_nar_hit INTEGER,
  nar_hits INTEGER NOT NULL DEFAULT 0,
  last_narinfo_hit INTEGER,
  narinfo_hits INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS users (
  name TEXT PRIMARY KEY,
  last_ok INTEGER,
  recent_fails INTEGER NOT NULL DEFAULT 0,
  last_alert INTEGER
);
CREATE TABLE IF NOT EXISTS ingest (
  log TEXT PRIMARY KEY,
  inode INTEGER NOT NULL,
  offset INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS notices (
  key TEXT PRIMARY KEY,
  at INTEGER NOT NULL
);
"""


@dataclass(frozen=True)
class Hits:
    last_nar_hit: int | None
    last_narinfo_hit: int | None


def open_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    return conn


def load_hits(conn: sqlite3.Connection) -> dict[str, Hits]:
    rows = conn.execute("SELECT hash, last_nar_hit, last_narinfo_hit FROM paths")
    return {h: Hits(nar, narinfo) for h, nar, narinfo in rows}


def notice_seen(conn: sqlite3.Connection, key: str) -> bool:
    return conn.execute("SELECT 1 FROM notices WHERE key = ?", (key,)).fetchone() is not None


def mark_notice(conn: sqlite3.Connection, key: str, at: int) -> None:
    conn.execute(
        "INSERT INTO notices(key, at) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET at = excluded.at",
        (key, at),
    )
