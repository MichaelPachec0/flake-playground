from pathlib import Path

from helpers import store_path
from nix_cache.db import Hits
from nix_cache.graph import build_graph, store_hash
from nix_cache.pins import Namespace, Pin
from nix_cache.retention import Policy, plan_retention

NS = Namespace("flake-playground", "gate", "x86_64-linux")
OLD_NS = Namespace("flake-playground", "bump-picr", "x86_64-linux")
DAY = 86400
NOW = 100 * DAY
DRV = store_path(500, "foo-1.0.drv")


def info(refs=(), size=10, deriver=None, reg=0):
    return {"narSize": size, "references": list(refs), "deriver": deriver, "registrationTime": reg}


def mkpin(ns, stamp, *targets):
    return Pin(ns, stamp, Path(f"/pins/{ns}/{stamp}"), tuple(sorted(targets)))


def plan(graph_info, pins, *, budget=1000, hits=None, system=frozenset(), previous=frozenset(), latest=None, protect=DAY):
    g = build_graph(graph_info)
    return plan_retention(
        graph=g,
        pins=pins,
        latest=latest or {},
        previous_keep=set(previous),
        hits=hits or {},
        system_paths=set(system),
        policy=Policy(budget_bytes=budget, active_seconds=30 * DAY, protect_seconds=protect),
        now=NOW,
    )


LATEST = store_path(1, "latest")
LIB = store_path(2, "lib")


def test_keeps_latest_closure_even_over_budget():
    p_old, p_new = mkpin(NS, NOW - 2 * DAY, store_path(3, "old")), mkpin(NS, NOW - DAY, LATEST)
    r = plan({LATEST: info([LIB]), LIB: info(), store_path(3, "old"): info()}, [p_old, p_new], budget=5)
    assert {LATEST, LIB} <= r.keep
    assert r.over_budget and r.kept_bytes == 20
    assert r.delete_pins == (p_old,)


def test_tier_order_fills_budget_with_out_then_dev():
    out, dev, doc, dbg = (store_path(i, n) for i, n in enumerate(["foo-1.0", "foo-1.0-dev", "foo-1.0-doc", "foo-1.0-debug"], 10))
    g = {LATEST: info(size=1), **{p: info(deriver=DRV) for p in (out, dev, doc, dbg)}}
    pins = [mkpin(NS, NOW - 3 * DAY, out, dev, doc, dbg), mkpin(NS, NOW - DAY, LATEST)]
    r = plan(g, pins, budget=21)
    assert {LATEST, out, dev} <= r.keep
    assert doc not in r.keep and dbg not in r.keep
    assert [p.stamp for p in r.delete_pins] == [NOW - 3 * DAY]


def test_lru_within_a_tier():
    p1, p2 = store_path(20, "p1"), store_path(21, "p2")
    hits = {store_hash(p1): Hits(100, None), store_hash(p2): Hits(200, None)}
    pins = [mkpin(NS, NOW - 3 * DAY, p1, p2), mkpin(NS, NOW - DAY, LATEST)]
    r = plan({LATEST: info(size=1), p1: info(), p2: info()}, pins, budget=11, hits=hits)
    assert p2 in r.keep and p1 not in r.keep


def test_ties_prefer_newer_registration():
    p1, p2 = store_path(20, "p1"), store_path(21, "p2")
    pins = [mkpin(NS, NOW - 3 * DAY, p1, p2), mkpin(NS, NOW - DAY, LATEST)]
    r = plan({LATEST: info(size=1), p1: info(reg=1), p2: info(reg=2)}, pins, budget=11)
    assert p2 in r.keep and p1 not in r.keep


def test_fresh_registrations_are_protected():
    fresh = store_path(30, "fresh")
    r = plan({LATEST: info(), fresh: info(reg=NOW - 60)}, [mkpin(NS, NOW - DAY, LATEST)], budget=0)
    assert fresh in r.keep


def test_recent_narinfo_hits_are_protected():
    probed = store_path(31, "probed")
    hits = {store_hash(probed): Hits(None, NOW - 60)}
    r = plan({LATEST: info(), probed: info()}, [mkpin(NS, NOW - DAY, LATEST)], budget=0, hits=hits)
    assert probed in r.keep


def test_expired_namespace_loses_protection():
    stale = store_path(40, "stale")
    pins = [mkpin(OLD_NS, NOW - 40 * DAY, stale), mkpin(NS, NOW - DAY, LATEST)]
    r = plan({LATEST: info(), stale: info()}, pins, budget=10)
    assert r.expired == (OLD_NS,)
    assert stale not in r.keep
    assert [p.namespace for p in r.delete_pins] == [OLD_NS]


def test_candidate_brings_its_references_and_keep_is_closed():
    app, dep = store_path(50, "app"), store_path(51, "dep")
    g = {LATEST: info(size=1), app: info([dep], size=5), dep: info(size=5)}
    r = plan(g, [mkpin(NS, NOW - 3 * DAY, app), mkpin(NS, NOW - DAY, LATEST)], budget=11)
    assert {app, dep} <= r.keep
    built = build_graph(g)
    assert all(ref in r.keep for p in r.keep for ref in built[p].references)
    assert r.tops == frozenset({LATEST, app})


def test_candidate_that_does_not_fit_is_skipped():
    app, dep = store_path(50, "app"), store_path(51, "dep")
    g = {LATEST: info(size=1), app: info([dep], size=5), dep: info(size=5)}
    r = plan(g, [mkpin(NS, NOW - 3 * DAY, app), mkpin(NS, NOW - DAY, LATEST)], budget=8)
    assert app not in r.keep
    assert dep in r.keep  # fits on its own (5 + 1 <= 8)


def test_system_paths_are_not_charged():
    sys_lib = store_path(60, "glibc")
    g = {LATEST: info([sys_lib], size=1), sys_lib: info(size=500)}
    r = plan(g, [mkpin(NS, NOW - DAY, LATEST)], budget=10, system={sys_lib})
    assert not r.over_budget and r.kept_bytes == 1


def test_previous_keep_stays_a_candidate():
    kept_before = store_path(70, "kept-before")
    r = plan({LATEST: info(size=1), kept_before: info()}, [mkpin(NS, NOW - DAY, LATEST)], budget=100, previous={kept_before})
    assert kept_before in r.keep


def test_latest_pointer_wins_over_newest_stamp():
    a, b = store_path(80, "a"), store_path(81, "b")
    pins = [mkpin(NS, NOW - 2 * DAY, a), mkpin(NS, NOW - DAY, b)]
    r = plan({a: info(), b: info()}, pins, budget=0, latest={NS: NOW - 2 * DAY}, protect=0)
    assert a in r.keep and b not in r.keep
