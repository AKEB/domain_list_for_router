#!/usr/bin/env python3
"""Build current overlap report for lists/*.txt."""

from __future__ import annotations

import ipaddress
import re
from collections import defaultdict
from pathlib import Path

DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$"
)


def parse_network(value: str):
    try:
        return ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None


def is_domain(value: str) -> bool:
    if "/" in value:
        return False
    return bool(DOMAIN_RE.fullmatch(value))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    lists_dir = repo_root / "lists"
    files = sorted(lists_dir.glob("*.txt"))

    domain_locations: dict[str, list[tuple[str, int]]] = defaultdict(list)
    networks: list[tuple[ipaddress._BaseNetwork, str, int]] = []
    invalid_entries: list[tuple[str, int, str]] = []

    for txt_file in files:
        lines = txt_file.read_text(encoding="utf-8").splitlines()
        for line_no, line in enumerate(lines, start=1):
            raw = line.strip()
            value = raw.lower().rstrip(".")
            if not value or value.startswith("#"):
                continue

            net = parse_network(value)
            if net is not None:
                networks.append((net, txt_file.name, line_no))
                continue

            if is_domain(value):
                domain_locations[value].append((txt_file.name, line_no))
                continue

            invalid_entries.append((txt_file.name, line_no, raw))

    duplicate_domains: list[tuple[str, list[tuple[str, int]]]] = []
    for domain, locations in domain_locations.items():
        file_set = {name for name, _line in locations}
        if len(file_set) > 1:
            duplicate_domains.append((domain, locations))
    duplicate_domains.sort(key=lambda item: item[0])

    parent_child_domains: list[
        tuple[str, str, list[tuple[str, int]], list[tuple[str, int]]]
    ] = []
    all_domains = set(domain_locations.keys())
    for domain in sorted(all_domains):
        labels = domain.split(".")
        for idx in range(1, len(labels) - 1):
            parent = ".".join(labels[idx:])
            if parent in all_domains:
                parent_child_domains.append(
                    (
                        domain,
                        parent,
                        domain_locations[domain],
                        domain_locations[parent],
                    )
                )
                break

    network_overlaps: list[tuple[str, str]] = []
    for i, (net_a, file_a, line_a) in enumerate(networks):
        for net_b, file_b, line_b in networks[i + 1 :]:
            if net_a.version != net_b.version:
                continue

            if net_a == net_b:
                if file_a != file_b:
                    network_overlaps.append(
                        (
                            str(net_a),
                            f"duplicate in {file_a}:{line_a} and {file_b}:{line_b}",
                        )
                    )
                continue

            if net_a.subnet_of(net_b):
                network_overlaps.append(
                    (
                        str(net_a),
                        f"{file_a}:{line_a} narrower than {net_b} at {file_b}:{line_b}",
                    )
                )
            elif net_b.subnet_of(net_a):
                network_overlaps.append(
                    (
                        str(net_b),
                        f"{file_b}:{line_b} narrower than {net_a} at {file_a}:{line_a}",
                    )
                )

    report_path = repo_root / "lists-overlap-report.txt"
    with report_path.open("w", encoding="utf-8") as report:
        report.write("CURRENT LIST INTERSECTIONS REPORT\n\n")

        report.write(f"Invalid entries: {len(invalid_entries)}\n")
        for file_name, line_no, value in invalid_entries:
            report.write(f"  - {file_name}:{line_no} -> {value}\n")
        report.write("\n")

        report.write(f"Duplicate domains across files: {len(duplicate_domains)}\n")
        for domain, locations in duplicate_domains:
            points = ", ".join(f"{file_name}:{line_no}" for file_name, line_no in sorted(locations))
            report.write(f"  - {domain}: {points}\n")
        report.write("\n")

        report.write(f"Domain parent-child overlaps: {len(parent_child_domains)}\n")
        for domain, parent, child_locations, parent_locations in parent_child_domains:
            child_points = ", ".join(
                f"{file_name}:{line_no}" for file_name, line_no in sorted(child_locations)
            )
            parent_points = ", ".join(
                f"{file_name}:{line_no}" for file_name, line_no in sorted(parent_locations)
            )
            report.write(
                f"  - {domain} (at {child_points}) narrower than {parent} (at {parent_points})\n"
            )
        report.write("\n")

        report.write(f"Network overlaps (narrower/duplicate): {len(network_overlaps)}\n")
        for network, description in network_overlaps:
            report.write(f"  - {network}: {description}\n")

    print(f"Report written: {report_path}")
    print(
        "counts: "
        f"invalid={len(invalid_entries)} "
        f"domain_duplicates={len(duplicate_domains)} "
        f"domain_overlaps={len(parent_child_domains)} "
        f"network_overlaps={len(network_overlaps)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
