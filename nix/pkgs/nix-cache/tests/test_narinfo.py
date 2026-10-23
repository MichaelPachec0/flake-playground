import pytest

from helpers import narinfo_text, nar_url, store_path
from nix_cache.narinfo import NarInfoError, parse_narinfo

P = store_path(1, "hello-2.12")
DEP = store_path(2, "glibc-2.40")
DRV = store_path(3, "hello-2.12.drv")


def test_parse_full():
    info = parse_narinfo(
        narinfo_text(P, references=[P, DEP], deriver=DRV, sigs=["a-1:x", "b-1:y"])
    )
    assert info.store_path == P
    assert info.url == nar_url(P)
    assert info.nar_size == 4
    assert info.references == (P, DEP)
    assert info.deriver == DRV
    assert info.key_names == frozenset({"a-1", "b-1"})


def test_no_references_no_deriver_no_sigs():
    info = parse_narinfo(narinfo_text(P, sigs=()))
    assert info.references == () and info.deriver is None and info.key_names == frozenset()


def test_unknown_deriver_is_none():
    text = narinfo_text(P) + "Deriver: unknown-deriver\n"
    assert parse_narinfo(text).deriver is None


@pytest.mark.parametrize(
    "mutate",
    [
        lambda t: t.replace("StorePath: ", "StorePath:"),
        lambda t: "\n".join(l for l in t.splitlines() if not l.startswith("NarHash")),
        lambda t: t.replace(nar_url(P), "../../etc/passwd"),
        lambda t: t.replace("NarSize: 4", "NarSize: four"),
        lambda t: t + "NarSize: 5\n",
        lambda t: t.replace(f"StorePath: {P}", "StorePath: /tmp/x"),
        lambda t: t.replace("References: ", "References: ../x "),
    ],
)
def test_rejects(mutate):
    with pytest.raises(NarInfoError):
        parse_narinfo(mutate(narinfo_text(P)))
