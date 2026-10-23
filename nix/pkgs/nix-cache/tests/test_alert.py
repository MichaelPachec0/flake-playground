import json
import sys

from nix_cache import alert


def sink(tmp_path, rc=0):
    out = tmp_path / "sent.jsonl"
    script = tmp_path / "sink"
    script.write_text(
        f"#!{sys.executable}\nimport json,sys\n"
        f"open({str(out)!r},'a').write(json.dumps([sys.argv[1], sys.stdin.read()])+'\\n')\n"
        f"sys.exit({rc})\n"
    )
    script.chmod(0o755)
    return script, out


def test_queue_and_flush(tmp_path):
    spool, deferred = tmp_path / "alerts", tmp_path / "deferred"
    alert.queue_alert(spool, "title one", "body one")
    alert.queue_alert(spool, "title two", "body two")
    script, out = sink(tmp_path)
    assert alert.flush(spool, deferred, str(script)) == 0
    sent = [json.loads(l) for l in out.read_text().splitlines()]
    assert sent == [["title one", "body one"], ["title two", "body two"]]
    assert list(spool.iterdir()) == []


def test_failed_delivery_is_deferred_then_requeued(tmp_path):
    spool, deferred = tmp_path / "alerts", tmp_path / "deferred"
    alert.queue_alert(spool, "t", "b")
    script, _ = sink(tmp_path, rc=1)
    assert alert.flush(spool, deferred, str(script)) == 1
    assert list(spool.iterdir()) == [] and len(list(deferred.iterdir())) == 1
    alert.requeue(deferred, spool)
    assert len(list(spool.iterdir())) == 1 and list(deferred.iterdir()) == []


def test_corrupt_spool_entry_is_dropped(tmp_path):
    spool, deferred = tmp_path / "alerts", tmp_path / "deferred"
    spool.mkdir()
    (spool / "1-x.json").write_text("{not json")
    script, out = sink(tmp_path)
    assert alert.flush(spool, deferred, str(script)) == 0
    assert not out.exists() and list(spool.iterdir()) == []
