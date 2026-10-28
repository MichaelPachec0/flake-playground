"""Tiered LRU retention planner. Pure: the pruner feeds it state and applies the result.

Instead of evicting, it grows the keep set from the must-keep core in value
order (tier, then recency) while the budget allows. Every addition is a
closure, so the keep set is always closed under references and can be
rooted by its tops alone.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from .db import Hits
from .graph import Node, closure, closure_excluding, output_names, store_hash, tier
from .pins import Namespace, Pin

if TYPE_CHECKING:
    from .config import Config


@dataclass(frozen=True)
class Policy:
    budget_bytes: int
    active_seconds: int
    protect_seconds: int

    @classmethod
    def from_config(
        cls,
        cfg: Config,
        *,
        budget_bytes: int | None = None,
        active_days: int | None = None,
        protect_hours: int | None = None,
    ) -> Policy:
        """The policy cfg describes; the pruner's CLI overrides replace single fields."""
        return cls(
            budget_bytes=cfg.budget_bytes if budget_bytes is None else budget_bytes,
            active_seconds=86400 * (cfg.active_days if active_days is None else active_days),
            protect_seconds=3600 * (cfg.protect_hours if protect_hours is None else protect_hours),
        )


@dataclass(frozen=True)
class RetentionPlan:
    keep: frozenset[str]
    tops: frozenset[str]
    delete_pins: tuple[Pin, ...]
    expired: tuple[Namespace, ...]
    kept_bytes: int
    over_budget: bool


@dataclass(frozen=True)
class _Core:
    expired: tuple[Namespace, ...]
    protected_pins: frozenset[tuple[Namespace, int]]
    must: frozenset[str]


def _core(
    graph: dict[str, Node],
    pins: list[Pin],
    latest: dict[Namespace, int],
    hits: dict[str, Hits],
    policy: Policy,
    now: int,
) -> _Core:
    """The must-keep core: latest pin of each active namespace, plus fresh paths."""
    newest: dict[Namespace, int] = {}
    for p in pins:
        newest[p.namespace] = max(newest.get(p.namespace, 0), p.stamp)
    active = {ns for ns, stamp in newest.items() if now - stamp <= policy.active_seconds}
    expired = tuple(sorted(set(newest) - active, key=str))

    by_key = {(p.namespace, p.stamp): p for p in pins}
    protected_pins: set[tuple[Namespace, int]] = set()
    must: set[str] = set()
    for ns in active:
        key = (ns, latest[ns]) if (ns, latest.get(ns)) in by_key else (ns, newest[ns])
        protected_pins.add(key)
        must.update(by_key[key].targets)

    cutoff = now - policy.protect_seconds
    for p, node in graph.items():
        h = hits.get(store_hash(p))
        if node.registration_time >= cutoff or (
            h is not None and h.last_narinfo_hit is not None and h.last_narinfo_hit >= cutoff
        ):
            must.add(p)
    return _Core(expired, frozenset(protected_pins), frozenset(must))


def _charge(graph: dict[str, Node], paths, system_paths: set[str]) -> int:
    return sum(graph[p].nar_size for p in paths if p not in system_paths)


def protected_bytes(
    graph: dict[str, Node],
    pins: list[Pin],
    latest: dict[Namespace, int],
    hits: dict[str, Hits],
    system_paths: set[str],
    policy: Policy,
    now: int,
) -> int:
    """Bytes retention keeps whatever the budget: the closure of the must-keep core.

    Equals plan_retention's kept_bytes when the plan is over budget.
    """
    core = _core(graph, pins, latest, hits, policy, now)
    return _charge(graph, closure(graph, core.must), system_paths)


def plan_retention(
    graph: dict[str, Node],
    pins: list[Pin],
    latest: dict[Namespace, int],
    previous_keep: set[str],
    hits: dict[str, Hits],
    system_paths: set[str],
    policy: Policy,
    now: int,
) -> RetentionPlan:
    core = _core(graph, pins, latest, hits, policy, now)
    expired, protected_pins = core.expired, core.protected_pins
    keep = closure(graph, core.must)

    def charge(paths) -> int:
        return _charge(graph, paths, system_paths)

    used = charge(keep)
    over = used > policy.budget_bytes

    if not over:
        pool = closure(graph, [t for p in pins for t in p.targets] + list(previous_keep)) - keep
        outputs = output_names(graph)

        def value(p: str):
            h = hits.get(store_hash(p))
            last = h.last_nar_hit if h is not None and h.last_nar_hit is not None else 0
            return (-tier(outputs[p]), -last, -graph[p].registration_time, p)

        for p in sorted(pool, key=value):
            if p in keep:
                continue
            extra = closure_excluding(graph, p, keep)
            cost = charge(extra)
            if used + cost <= policy.budget_bytes:
                keep |= extra
                used += cost

    referenced = {r for p in keep for r in graph[p].references}
    tops = frozenset(p for p in keep if p not in referenced)
    delete = tuple(
        p
        for p in pins
        if (p.namespace, p.stamp) not in protected_pins and not set(p.targets) <= keep
    )
    return RetentionPlan(
        keep=frozenset(keep),
        tops=tops,
        delete_pins=delete,
        expired=expired,
        kept_bytes=used,
        over_budget=over,
    )
