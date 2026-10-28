import base64
import hashlib
import io

import pytest

from nix_cache import htpasswd

TOKEN = "q-yPCWrYknxVswqi5Lu33h83B4da9eWq2QfAq33hjb8"


def test_ssha_layout_is_digest_then_salt():
    hashed = htpasswd.ssha(TOKEN, salt=b"\x00" * 8)
    assert hashed.startswith("{SSHA}")
    raw = base64.b64decode(hashed[len("{SSHA}"):])
    assert len(raw) == 28
    assert raw[20:] == b"\x00" * 8
    assert raw[:20] == hashlib.sha1(TOKEN.encode() + b"\x00" * 8).digest()


def test_check_ssha_roundtrip():
    hashed = htpasswd.ssha(TOKEN)
    assert htpasswd.check_ssha(hashed, TOKEN)
    assert not htpasswd.check_ssha(hashed, TOKEN + "x")


def test_salt_is_random():
    assert htpasswd.ssha(TOKEN) != htpasswd.ssha(TOKEN)


@pytest.mark.parametrize("user", ["nyx", "Nyx-g1", "nyx-g", "-g1", "nyx g1-g1", "nyx-g1\n"])
def test_entry_rejects_bad_user(user):
    with pytest.raises(htpasswd.EntryError):
        htpasswd.entry(user, TOKEN)


@pytest.mark.parametrize("token", ["short", TOKEN[:42], TOKEN + ":x", TOKEN + " x"])
def test_entry_rejects_bad_token(token):
    with pytest.raises(htpasswd.EntryError):
        htpasswd.entry("nyx-g1", token)


def test_entry_format():
    line = htpasswd.entry("ci-flake-playground-g1", TOKEN)
    user, hashed = line.split(":", 1)
    assert user == "ci-flake-playground-g1"
    assert htpasswd.check_ssha(hashed, TOKEN)


def test_new_token_is_43_chars():
    assert len(htpasswd.new_token()) == 43


def test_main_reads_token_from_stdin(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO(TOKEN + "\n"))
    assert htpasswd.main(["nyx-g1"]) == 0
    user, hashed = capsys.readouterr().out.strip().split(":", 1)
    assert user == "nyx-g1" and htpasswd.check_ssha(hashed, TOKEN)


def test_main_new_prints_token_then_entry(capsys):
    assert htpasswd.main(["--new", "nyx-g2"]) == 0
    token, line = capsys.readouterr().out.strip().splitlines()
    assert htpasswd.check_ssha(line.split(":", 1)[1], token)


def test_main_rejects_bad_user(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO(TOKEN + "\n"))
    assert htpasswd.main(["nyx"]) == 2
    assert "nix-cache-htpasswd-entry:" in capsys.readouterr().err
