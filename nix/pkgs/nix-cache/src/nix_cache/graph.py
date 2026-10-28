"""The store as a graph, plus output-class detection for tiered eviction."""

from __future__ import annotations

import os
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass

TIER_BY_OUTPUT = {"debug": 0, "doc": 1, "devdoc": 1, "man": 1, "info": 1, "dev": 2}
DEFAULT_TIER = 3


@dataclass(frozen=True)
class Node:
    path: str
    nar_size: int
    references: frozenset[str]
    deriver: str | None
    registration_time: int


def build_graph(info: dict[str, dict]) -> dict[str, Node]:
    return {
        p: Node(
            path=p,
            nar_size=int(i.get("narSize") or 0),
            references=frozenset(r for r in i.get("references", []) if r != p),
            deriver=i.get("deriver"),
            registration_time=int(i.get("registrationTime") or 0),
        )
        for p, i in info.items()
    }


def store_hash(path: str) -> str:
    return path.rsplit("/", 1)[-1][:32]


def path_name(path: str) -> str:
    return path.rsplit("/", 1)[-1][33:]


def closure(graph: dict[str, Node], roots: Iterable[str]) -> set[str]:
    seen: set[str] = set()
    stack = [r for r in roots if r in graph]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        stack.extend(r for r in graph[p].references if r in graph and r not in seen)
    return seen


def system_closure(graph: dict[str, Node], roots: Iterable[str]) -> set[str]:
    """Closure of the host's own system roots (symlinks such as /run/current-system)."""
    return closure(graph, [os.path.realpath(r) for r in roots if os.path.exists(r)])


def closure_excluding(graph: dict[str, Node], root: str, exclude: set[str]) -> set[str]:
    """Closure of root, not descending into paths already in exclude."""
    if root in exclude or root not in graph:
        return set()
    seen = {root}
    stack = [root]
    while stack:
        p = stack.pop()
        for r in graph[p].references:
            if r in graph and r not in seen and r not in exclude:
                seen.add(r)
                stack.append(r)
    return seen


def output_names(graph: dict[str, Node]) -> dict[str, str]:
    groups: dict[str, list[str]] = defaultdict(list)
    for p, node in graph.items():
        groups[node.deriver or p].append(p)
    result: dict[str, str] = {}
    for members in groups.values():
        if len(members) == 1:
            result[members[0]] = "out"
            continue
        names = {p: path_name(p) for p in members}
        shortest = min(names.values(), key=len)
        if all(n == shortest or n.startswith(shortest + "-") for n in names.values()):
            base = shortest
        else:
            prefix = os.path.commonprefix(list(names.values()))
            cut = prefix.rfind("-")
            base = prefix[:cut] if cut > 0 else ""
        for p, n in names.items():
            if base and n != base and n.startswith(base + "-"):
                result[p] = n[len(base) + 1 :]
            else:
                result[p] = "out"
    return result


def tier(output: str) -> int:
    return TIER_BY_OUTPUT.get(output, DEFAULT_TIER)
