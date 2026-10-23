import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from helpers import narinfo_text, store_path
from nix_cache import bundle, nixcli
from nix_cache.graph import store_hash
from nix_cache.nixcli import NixError

R1, R2, R3 = store_path(1, "r1"), store_path(2, "r2"), store_path(3, "r3")
D_UP, D_OWN, D_NEW = store_path(4, "glibc"), store_path(5, "lib"), store_path(6, "new")
# Pseudo statuses for the fake cache: a malformed status line, a body cut short.
BAD_STATUS_LINE, TRUNCATED = -1, -2
SECRET = "s3cr3t-T0KEN-do-not-log"


@pytest.fixture
def server():
    present: set[str] = set()
    seen_auth: list[str | None] = []
    busy: dict[str, list[int]] = {}  # hash -> statuses to answer before the real one

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            seen_auth.append(self.headers.get("Authorization"))
            h = self.path.strip("/").removesuffix(".narinfo")
            if busy.get(h):
                status = busy[h].pop(0)
                self.close_connection = True
                if status == BAD_STATUS_LINE:
                    self.wfile.write(b"garbage\r\n\r\n")
                elif status == TRUNCATED:
                    self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort")
                else:
                    self.send_response(status)
                    self.end_headers()
                return
            body = f"StorePath: /nix/store/{h}-x\n".encode()
            self.send_response(200 if h in present else 404)
            self.send_header("Content-Length", str(len(body) if h in present else 0))
            self.end_headers()
            if h in present:
                self.wfile.write(body)

        def log_message(self, *args):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", present, seen_auth, busy
    srv.shutdown()


@pytest.fixture
def no_retry_wait(monkeypatch):
    monkeypatch.setattr(bundle, "RETRY_DELAYS", (0.0, 0.0, 0.0))


def test_present_on_sends_netrc_auth(tmp_path, server):
    url, present, seen_auth, _ = server
    present.add(store_hash(R1))
    netrc = tmp_path / "netrc"
    netrc.write_text("machine 127.0.0.1 login ci-g1 password s3cret\n")
    opener = bundle.own_opener(netrc, url)
    assert bundle.present_on(opener, url, [R1, R2], jobs=4) == {R1}
    assert seen_auth[0] == "Basic " + base64.b64encode(b"ci-g1:s3cret").decode()


def test_present_on_unreachable_raises(no_retry_wait):
    opener = bundle.own_opener(None, "http://127.0.0.1:9")
    with pytest.raises(bundle.ProbeError, match="after 4 attempts"):
        bundle.present_on(opener, "http://127.0.0.1:9", [R1], jobs=1)


def test_present_on_retries_busy_cache(server, no_retry_wait):
    url, present, _, busy = server
    present.add(store_hash(R1))
    busy[store_hash(R1)] = [503, 429]
    busy[store_hash(R2)] = [502]
    assert bundle.present_on(bundle.own_opener(None, url), url, [R1, R2], jobs=2) == {R1}


def test_present_on_raises_when_cache_stays_busy(server, no_retry_wait):
    url, present, _, busy = server
    present.add(store_hash(R1))
    busy[store_hash(R1)] = [503] * 4
    with pytest.raises(bundle.ProbeError, match="HTTP 503"):
        bundle.present_on(bundle.own_opener(None, url), url, [R1], jobs=1)


def test_present_on_retries_broken_http_responses(server, no_retry_wait):
    url, present, _, busy = server
    present.add(store_hash(R1))
    busy[store_hash(R1)] = [BAD_STATUS_LINE, TRUNCATED]
    busy[store_hash(R2)] = [TRUNCATED]
    assert bundle.present_on(bundle.own_opener(None, url), url, [R1, R2], jobs=2) == {R1}


def test_present_on_raises_when_responses_stay_broken(server, no_retry_wait):
    url, _, _, busy = server
    busy[store_hash(R1)] = [BAD_STATUS_LINE] * 4
    with pytest.raises(bundle.ProbeError, match="after 4 attempts"):
        bundle.present_on(bundle.own_opener(None, url), url, [R1], jobs=1)


def info(path, refs):
    return {"narHash": "sha256-" + "A" * 43 + "=", "narSize": 4, "references": list(refs), "deriver": None}


class Fakes:
    """Fake caches and nix. The fake `nix copy` enforces the Nix 2.34 rule
    that every reference must be in the batch or already have a narinfo in
    OUT, and records which narinfos OUT held when the copy started."""

    def __init__(self):
        self.copied: list[str] = []
        self.at_copy: dict[str, str] = {}  # narinfo file name -> body, seen by the copy
        self.by_base = {"own": {R1, D_OWN}, "up": {D_UP}}
        self.bodies = {p: narinfo_text(p) for p in (R1, D_OWN, D_UP)}
        # R2 -> D_NEW, D_OWN; D_NEW -> D_UP; D_OWN -> D_UP
        self.closure = {
            R2: info(R2, [R2, D_NEW, D_OWN]),
            D_NEW: info(D_NEW, [D_UP]),
            D_OWN: info(D_OWN, [D_UP]),
            D_UP: info(D_UP, []),
        }


@pytest.fixture
def fakes(monkeypatch):
    f = Fakes()
    monkeypatch.setattr(
        bundle, "fetch_present",
        lambda opener, base, paths, jobs: {p: f.bodies[p] for p in paths if p in f.by_base.get(base, set())},
    )
    monkeypatch.setattr(nixcli, "invalid_paths", lambda paths: {p for p in paths if p == R3})
    monkeypatch.setattr(nixcli, "path_info", lambda paths, recursive=False: dict(f.closure))

    def fake_nix(*args, stdin=None):
        assert args[:3] == ("copy", "--no-recursive", "--to")
        out = Path(args[3].split("://", 1)[1].split("?", 1)[0])
        batch = stdin.split()
        for p in batch:
            for r in f.closure[p]["references"]:
                if r not in batch and not (out / f"{store_hash(r)}.narinfo").is_file():
                    raise NixError(f"cannot add path '{p}' because the reference '{r}' is not valid")
        f.at_copy = {n.name: n.read_text() for n in out.glob("*.narinfo")}
        for d in ("nar", "log", "realisations"):
            (out / d).mkdir(exist_ok=True)
        (out / "nix-cache-info").write_text("StoreDir: /nix/store\n")
        for p in batch:
            (out / f"{store_hash(p)}.narinfo").write_text(narinfo_text(p, sigs=()))
            f.copied.append(p)
        return ""

    monkeypatch.setattr(nixcli, "nix", fake_nix)
    return f


def make(tmp_path, roots, **kw):
    args = dict(roots=roots, set_="gate", arch="x86_64-linux", out=tmp_path / "bundle",
                upstreams=["up"], own_url="own", netrc_file=None, run_id="7", commit="abc")
    args.update(kw)
    return bundle.make_bundle(**args)


def test_make_bundle(tmp_path, fakes, capsys):
    m = make(tmp_path, [R1, R2, R3])
    assert m.roots == tuple(sorted([R1, R2]))
    assert m.paths == tuple(sorted([R2, D_NEW]))
    assert sorted(fakes.copied) == sorted([R2, D_NEW])
    out = tmp_path / "bundle"
    assert not (out / "log").exists() and not (out / "realisations").exists()
    assert json.loads((out / "manifest.json").read_text())["roots"] == sorted([R1, R2])
    assert f"skipping {R3}" in capsys.readouterr().err


def test_root_served_upstream_is_still_shipped(tmp_path, fakes):
    # The importer no longer substitutes roots, so a locally built root must
    # ride in the bundle even when upstream has it; a non-root path upstream
    # serves is still left out; a root the own cache serves is not shipped.
    fakes.by_base["up"] |= {R2, D_NEW}
    fakes.bodies[R2] = narinfo_text(R2)
    fakes.bodies[D_NEW] = narinfo_text(D_NEW)
    m = make(tmp_path, [R1, R2])
    assert m.roots == tuple(sorted([R1, R2]))
    assert m.paths == (R2,)
    assert fakes.copied == [R2]
    assert D_NEW not in m.paths and R1 not in m.paths
    assert (tmp_path / "bundle" / f"{store_hash(R2)}.narinfo").is_file()


def test_reference_narinfos_are_seeded_for_the_copy_then_removed(tmp_path, fakes):
    make(tmp_path, [R2])
    # Written before the copy: one narinfo per excluded reference, with the
    # body the cache answered the presence GET with.
    assert fakes.at_copy == {f"{store_hash(p)}.narinfo": fakes.bodies[p] for p in (D_OWN, D_UP)}
    # Gone afterwards: the bundle holds the missing paths only.
    left = sorted(n.name for n in (tmp_path / "bundle").glob("*.narinfo"))
    assert left == sorted(f"{store_hash(p)}.narinfo" for p in (R2, D_NEW))


def test_seed_falls_back_to_local_path_info(tmp_path, fakes):
    fakes.bodies[D_UP] = "not a narinfo\n"
    make(tmp_path, [R2])
    seed = fakes.at_copy[f"{store_hash(D_UP)}.narinfo"]
    assert seed.splitlines()[0] == f"StorePath: {D_UP}"
    assert f"NarHash: {fakes.closure[D_UP]['narHash']}" in seed.splitlines()
    assert not (tmp_path / "bundle" / f"{store_hash(D_UP)}.narinfo").exists()


def test_all_roots_cached_gives_manifest_only_bundle(tmp_path, fakes):
    m = make(tmp_path, [R1])
    assert m.paths == () and fakes.copied == []
    assert sorted(p.name for p in (tmp_path / "bundle").iterdir()) == ["manifest.json", "nix-cache-info"]


def test_nothing_to_pin(tmp_path, fakes):
    with pytest.raises(bundle.BundleToolError):
        make(tmp_path, [R3])


def test_refuses_non_empty_out(tmp_path, fakes):
    (tmp_path / "bundle").mkdir()
    (tmp_path / "bundle" / "x").write_text("x")
    with pytest.raises(bundle.BundleToolError):
        make(tmp_path, [R1])


def test_main_reads_roots_json(tmp_path, fakes):
    roots = tmp_path / "roots.json"
    roots.write_text(json.dumps([R1]))
    rc = bundle.main(["--roots-json", str(roots), "--set", "gate", "--arch", "x86_64-linux",
                      "--out", str(tmp_path / "bundle"), "--upstream", "up", "--own-cache", "own"])
    assert rc == 0


def test_main_probe_failure_exits_1(tmp_path, fakes, monkeypatch, capsys):
    def busy(opener, base, paths, jobs):
        raise bundle.ProbeError(f"{base}/x.narinfo: HTTP 503 after 4 attempts")

    monkeypatch.setattr(bundle, "fetch_present", busy)
    roots = tmp_path / "roots.json"
    roots.write_text(json.dumps([R1]))
    rc = bundle.main(["--roots-json", str(roots), "--set", "gate", "--arch", "x86_64-linux",
                      "--out", str(tmp_path / "bundle"), "--own-cache", "own"])
    assert rc == 1
    assert "HTTP 503" in capsys.readouterr().err


def run_main(tmp_path, roots, *extra):
    roots_file = tmp_path / "roots.json"
    roots_file.write_text(roots if isinstance(roots, str) else json.dumps(roots))
    return bundle.main(["--roots-json", str(roots_file), "--set", "gate", "--arch", "x86_64-linux",
                        "--out", str(tmp_path / "bundle"), "--no-upstream", *extra])


@pytest.mark.parametrize("text", [
    f"machine 127.0.0.1 login ci-g1 password {SECRET} bogus\n",
    f"{SECRET} machine 127.0.0.1 login ci-g1\n",
])
def test_malformed_netrc_never_leaks_its_contents(tmp_path, fakes, capsys, text):
    netrc_file = tmp_path / "netrc"
    netrc_file.write_text(text)
    rc = run_main(tmp_path, [R1], "--own-cache", "http://127.0.0.1:9", "--netrc", str(netrc_file))
    err = capsys.readouterr().err
    assert rc == 1
    assert "netrc" in err and SECRET not in err and "Traceback" not in err


def test_missing_netrc_exits_1(tmp_path, fakes, capsys):
    rc = run_main(tmp_path, [R1], "--own-cache", "own", "--netrc", str(tmp_path / "absent"))
    assert rc == 1
    assert "netrc" in capsys.readouterr().err


@pytest.mark.parametrize("jobs", ["0", "-1", "x"])
def test_jobs_must_be_positive(tmp_path, fakes, jobs):
    with pytest.raises(SystemExit) as exc:
        run_main(tmp_path, [R1], "--own-cache", "own", "--jobs", jobs)
    assert exc.value.code == 2


@pytest.mark.parametrize("roots", [
    "not json",
    {"roots": [R1]},
    [R1, 7],
    [R1, "/nix/store/a"],
    [R1, R2 + "\n"],
    [R1, "--option"],
])
def test_bad_roots_json_exits_2(tmp_path, fakes, capsys, roots):
    rc = run_main(tmp_path, roots, "--own-cache", "own")
    assert rc == 2
    assert "roots" in capsys.readouterr().err
    assert not (tmp_path / "bundle").exists()


def test_missing_roots_json_exits_2(tmp_path, fakes, capsys):
    rc = bundle.main(["--roots-json", str(tmp_path / "absent.json"), "--set", "gate", "--arch", "x86_64-linux",
                      "--out", str(tmp_path / "bundle"), "--no-upstream"])
    assert rc == 2
    assert "roots" in capsys.readouterr().err


def test_make_bundle_rejects_non_store_root(tmp_path, fakes):
    with pytest.raises(bundle.BundleToolError, match="roots"):
        make(tmp_path, [R1, "/nix/store/a"])
