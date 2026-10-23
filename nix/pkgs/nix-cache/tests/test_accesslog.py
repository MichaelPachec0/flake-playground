import json
import os

from helpers import fake_hash
from nix_cache.accesslog import ingest, parse_line
from nix_cache.db import load_hits, mark_notice, notice_seen, open_db

H1, H2 = fake_hash(1), fake_hash(2)


def line(uri, status=200, user="nyx-g1", t="2026-10-22T07:00:00+00:00"):
    return json.dumps({"t": t, "u": user, "uri": uri, "s": status, "b": 1}) + "\n"


T0 = 1792652400  # 2026-10-22T07:00:00Z


def test_parse_line():
    e = parse_line(line(f"/{H1}.narinfo").encode())
    assert (e.t, e.user, e.uri, e.status) == (T0, "nyx-g1", f"/{H1}.narinfo", 200)
    assert parse_line(b"garbage\n") is None
    assert parse_line(b'{"t":"x"}\n') is None


def test_parse_line_rejects_hostile_input():
    ok = {"t": "2026-10-22T07:00:00+00:00", "u": "a", "uri": "/x", "s": 200}
    for raw in (
        b"[]\n",
        b"null\n",
        b'"str"\n',
        b"\xff\xfe\n",
        b"[" * 100000 + b"\n",
        json.dumps({**ok, "s": 1e999}).encode(),
        json.dumps({**ok, "s": "x"}).encode(),
        json.dumps({**ok, "s": None}).encode(),
        json.dumps({**ok, "uri": {"a": 1}}).encode(),
        json.dumps({**ok, "uri": None}).encode(),
        json.dumps({**ok, "t": "0001-01-01T00:00:00+14:00"}).encode(),
        json.dumps({**ok, "t": "2026-10-22T07:00:00"}).encode(),
        json.dumps({**ok, "t": 5}).encode(),
    ):
        assert parse_line(raw) is None, raw


def test_parse_line_odd_users_are_ignored_not_fatal():
    for user in ("x" * 500, "a\nb", "a b", "café", "'; DROP TABLE users;--", 5, ["a"]):
        e = parse_line(line("/x", user=user).encode())
        assert e is not None and e.user == ""


def test_ingest_counts_hits(tmp_path):
    log = tmp_path / "access.log"
    log.write_text(
        line(f"/{H1}.narinfo")
        + line(f"/nar/{fake_hash(9, 52)}.nar?hash={H1}")
        + line(f"/nar/{fake_hash(8, 52)}.nar?foo=1&hash={H2}", status=206)
        + line(f"/{H2}.narinfo", status=404)
        + line("/nix-cache-info")
    )
    conn = open_db(tmp_path / "db.sqlite")
    ingest(conn, log)
    hits = load_hits(conn)
    assert hits[H1].last_narinfo_hit == T0 and hits[H1].last_nar_hit == T0
    assert hits[H2].last_nar_hit == T0 and hits[H2].last_narinfo_hit is None


def test_uri_matching_is_strict(tmp_path):
    log = tmp_path / "access.log"
    nar = fake_hash(9, 52)
    log.write_text(
        line(f"/{H1}.narinfo\n")  # trailing newline inside the URI
        + line(f"/nar/{nar}.nar?xhash={H2}")
        + line(f"/nar/{nar}.nar?hash={H2}x")
        + line(f"/other/{H2}.narinfo")
    )
    conn = open_db(tmp_path / "db.sqlite")
    ingest(conn, log)
    assert load_hits(conn) == {}


def test_bad_lines_do_not_stop_ingestion(tmp_path):
    log = tmp_path / "access.log"
    log.write_bytes(
        b"garbage\n" + b"\xff\n" + b"[" * 50000 + b"\n" + b"x" * 300000 + b"\n" + line(f"/{H1}.narinfo").encode()
    )
    conn = open_db(tmp_path / "db.sqlite")
    ingest(conn, log)
    assert set(load_hits(conn)) == {H1}


def test_ingest_is_incremental_and_skips_partial_lines(tmp_path):
    log = tmp_path / "access.log"
    conn = open_db(tmp_path / "db.sqlite")
    log.write_text(line(f"/{H1}.narinfo") + line(f"/{H2}.narinfo")[:10])
    ingest(conn, log)
    assert set(load_hits(conn)) == {H1}
    with open(log, "a") as f:
        f.write(line(f"/{H2}.narinfo")[10:])
    ingest(conn, log)
    assert set(load_hits(conn)) == {H1, H2}
    assert conn.execute("SELECT narinfo_hits FROM paths WHERE hash=?", (H1,)).fetchone()[0] == 1


def test_ingest_survives_logrotate(tmp_path):
    log = tmp_path / "access.log"
    conn = open_db(tmp_path / "db.sqlite")
    log.write_text(line(f"/{H1}.narinfo"))
    ingest(conn, log)
    with open(log, "a") as f:
        f.write(line(f"/{H2}.narinfo"))  # written before rotation, not yet ingested
    os.rename(log, tmp_path / "access.log.1")
    log.write_text(line(f"/nar/{fake_hash(9, 52)}.nar?hash={H1}"))
    ingest(conn, log)
    hits = load_hits(conn)
    assert hits[H2].last_narinfo_hit == T0
    assert hits[H1].last_nar_hit == T0
    assert conn.execute("SELECT narinfo_hits FROM paths WHERE hash=?", (H1,)).fetchone()[0] == 1


def test_ingest_handles_truncation(tmp_path):
    log = tmp_path / "access.log"
    conn = open_db(tmp_path / "db.sqlite")
    log.write_text(line(f"/{H1}.narinfo") * 3)
    ingest(conn, log)
    log.write_text(line(f"/{H2}.narinfo"))  # same inode, shorter
    ingest(conn, log)
    assert H2 in load_hits(conn)


def test_missing_log_is_fine(tmp_path):
    ingest(open_db(tmp_path / "db.sqlite"), tmp_path / "nope.log")


def test_user_success_and_failures(tmp_path):
    log = tmp_path / "access.log"
    conn = open_db(tmp_path / "db.sqlite")
    log.write_text(line("/nix-cache-info", user="nyx-g1") + line("/nix-cache-info", status=401, user="nyx-g1") * 3
                   + line("/nix-cache-info", status=401, user="") + line("/nix-cache-info", status=401, user="nobody-g1"))
    ingest(conn, log)
    rows = dict(conn.execute("SELECT name, recent_fails FROM users").fetchall())
    assert rows == {"nyx-g1": 3, "nobody-g1": 1}
    assert conn.execute("SELECT last_ok FROM users WHERE name='nobody-g1'").fetchone()[0] is None


def test_notices(tmp_path):
    conn = open_db(tmp_path / "db.sqlite")
    assert not notice_seen(conn, "k")
    mark_notice(conn, "k", 5)
    mark_notice(conn, "k", 6)
    assert notice_seen(conn, "k")
    assert conn.execute("SELECT at FROM notices").fetchone()[0] == 6
