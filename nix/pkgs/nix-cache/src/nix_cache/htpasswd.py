"""Render nginx htpasswd lines for cache read tokens.

nginx re-hashes the presented password on every request, inside the worker
event loop, with no cache. Read tokens are 32 random bytes, so a slow hash
buys nothing against guessing; {SSHA} (salted SHA-1) keeps a leaked htpasswd
file useless (no feasible preimage of a 256-bit random input) while each
check costs microseconds instead of milliseconds.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import re
import secrets
import sys

USER_RE = re.compile(r"^[a-z0-9][a-z0-9-]*-g[0-9]+$")
MIN_TOKEN_CHARS = 43  # 32 bytes in unpadded base64


class EntryError(ValueError):
    """The user name or token cannot be turned into an htpasswd line."""


def ssha(token: str, salt: bytes | None = None) -> str:
    if salt is None:
        salt = os.urandom(8)
    digest = hashlib.sha1(token.encode() + salt).digest()
    return "{SSHA}" + base64.b64encode(digest + salt).decode()


def check_ssha(hashed: str, token: str) -> bool:
    if not hashed.startswith("{SSHA}"):
        return False
    raw = base64.b64decode(hashed[len("{SSHA}"):])
    digest, salt = raw[:20], raw[20:]
    return hashlib.sha1(token.encode() + salt).digest() == digest


def entry(user: str, token: str, salt: bytes | None = None) -> str:
    if not USER_RE.match(user):
        raise EntryError(f"user {user!r} must look like <name>-g<N>, e.g. nyx-g1")
    if len(token) < MIN_TOKEN_CHARS:
        raise EntryError(
            f"token is {len(token)} chars; need at least {MIN_TOKEN_CHARS} (32 random bytes)"
        )
    if any(c in token for c in ": \t\r\n"):
        raise EntryError("token must not contain ':' or whitespace")
    return f"{user}:{ssha(token, salt)}"


def new_token() -> str:
    return secrets.token_urlsafe(32)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="nix-cache-htpasswd-entry",
        description="Print an nginx htpasswd line ({SSHA}) for a cache read token read from stdin.",
    )
    parser.add_argument("user", help="htpasswd user, <name>-g<N>")
    parser.add_argument(
        "--new",
        action="store_true",
        help="generate the token; print it on line 1 and the htpasswd line on line 2",
    )
    args = parser.parse_args(argv)
    token = new_token() if args.new else sys.stdin.readline().rstrip("\n")
    try:
        line = entry(args.user, token)
    except EntryError as e:
        print(f"nix-cache-htpasswd-entry: {e}", file=sys.stderr)
        return 2
    if args.new:
        print(token)
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
