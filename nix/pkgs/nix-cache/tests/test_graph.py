from helpers import store_path
from nix_cache.graph import (
    build_graph,
    closure,
    closure_excluding,
    output_names,
    path_name,
    store_hash,
    tier,
)

DRV = store_path(100, "foo-1.0.drv")


def info(refs=(), size=10, deriver=None, reg=0):
    return {"narSize": size, "references": list(refs), "deriver": deriver, "registrationTime": reg}


def test_build_graph_drops_self_references():
    p = store_path(1, "a")
    g = build_graph({p: info([p])})
    assert g[p].references == frozenset()


def test_helpers():
    p = store_path(1, "hello-2.12")
    assert len(store_hash(p)) == 32 and path_name(p) == "hello-2.12"


def test_closure_and_exclusion():
    a, b, c, d = (store_path(i, n) for i, n in enumerate("abcd", 1))
    g = build_graph({a: info([b]), b: info([c]), c: info(), d: info()})
    assert closure(g, [a]) == {a, b, c}
    assert closure(g, [a, "/nix/store/missing"]) == {a, b, c}
    assert closure_excluding(g, a, {b}) == {a}


def test_output_names_by_deriver():
    out, dev, man, debug = (store_path(i, n) for i, n in enumerate(["foo-1.0", "foo-1.0-dev", "foo-1.0-man", "foo-1.0-debug"], 1))
    g = build_graph({p: info(deriver=DRV) for p in (out, dev, man, debug)})
    assert output_names(g) == {out: "out", dev: "dev", man: "man", debug: "debug"}


def test_package_named_dev_alone_is_out():
    p = store_path(1, "foo-dev")
    assert output_names(build_graph({p: info(deriver=store_path(9, "foo-dev.drv"))})) == {p: "out"}


def test_no_out_output_uses_common_prefix():
    bin_, dev = store_path(1, "foo-1.0-bin"), store_path(2, "foo-1.0-dev")
    g = build_graph({bin_: info(deriver=DRV), dev: info(deriver=DRV)})
    assert output_names(g) == {bin_: "bin", dev: "dev"}


def test_no_deriver_is_out():
    p = store_path(1, "source")
    assert output_names(build_graph({p: info()})) == {p: "out"}


def test_tiers():
    assert [tier(o) for o in ("debug", "doc", "man", "info", "devdoc", "dev", "out", "lib", "bin")] == [0, 1, 1, 1, 1, 2, 3, 3, 3]
