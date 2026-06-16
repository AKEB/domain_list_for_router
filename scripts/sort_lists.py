#!/usr/bin/env python3
"""Sort list files: domains first, then IP/CIDR."""

from __future__ import annotations

import argparse
import ipaddress
import re
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


def domain_sort_key(value: str) -> tuple[str, ...]:
    # Sort by domain hierarchy from the top-level label to the left.
    return tuple(reversed(value.split(".")))


def network_sort_key(network: ipaddress._BaseNetwork) -> tuple[int, int, int]:
    return (network.version, int(network.network_address), network.prefixlen)


def sort_file(path: Path) -> bool:
    original_lines = path.read_text(encoding="utf-8").splitlines()

    domains: list[str] = []
    networks: list[tuple[str, ipaddress._BaseNetwork]] = []
    passthrough: list[str] = []

    for line in original_lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            passthrough.append(stripped)
            continue

        value = stripped.lower().rstrip(".")
        net = parse_network(value)
        if net is not None:
            networks.append((value, net))
            continue

        if is_domain(value):
            domains.append(value)
            continue

        passthrough.append(stripped)

    domains_sorted = sorted(dict.fromkeys(domains), key=domain_sort_key)
    unique_networks: dict[str, ipaddress._BaseNetwork] = {}
    for value, net in networks:
        unique_networks[value] = net
    networks_sorted_values = [
        value
        for value, net in sorted(
            unique_networks.items(),
            key=lambda item: network_sort_key(item[1]),
        )
    ]

    new_lines: list[str] = []
    if passthrough:
        new_lines.extend(passthrough)
    new_lines.extend(domains_sorted)
    new_lines.extend(networks_sorted_values)

    old_text = "\n".join(original_lines).rstrip("\n")
    new_text = "\n".join(new_lines).rstrip("\n")
    if new_text:
        new_text += "\n"

    if old_text != new_text.rstrip("\n"):
        path.write_text(new_text, encoding="utf-8")
        return True
    return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sort lists/*.txt: domains first, then IP/CIDR."
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="Optional list files relative to repo root. Default: all lists/*.txt",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent

    if args.files:
        files = [repo_root / rel for rel in args.files]
    else:
        files = sorted((repo_root / "lists").glob("*.txt"))

    changed = 0
    for file_path in files:
        if not file_path.exists():
            print(f"skip (not found): {file_path.relative_to(repo_root)}")
            continue
        if sort_file(file_path):
            changed += 1
            print(f"sorted: {file_path.relative_to(repo_root)}")

    print(f"done: changed {changed} file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
