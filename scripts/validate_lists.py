#!/usr/bin/env python3
"""Validate staged lists/*.txt before commit."""

from __future__ import annotations

import ipaddress
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

MAX_LINES_PER_FILE = 300
DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$"
)


def is_domain(value: str) -> bool:
    if "/" in value:
        return False
    return bool(DOMAIN_RE.fullmatch(value))


def parse_network(value: str):
    try:
        return ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None


def run_git(repo_root: Path, args: list[str]) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def get_staged_list_files(repo_root: Path) -> list[str]:
    output = run_git(
        repo_root,
        ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "--", "lists/*.txt"],
    )
    return sorted(line.strip() for line in output.splitlines() if line.strip())


def get_staged_added_lines(repo_root: Path, rel_path: str) -> list[tuple[int, str]]:
    patch = run_git(repo_root, ["diff", "--cached", "--unified=0", "--", rel_path])
    line_no = 0
    added: list[tuple[int, str]] = []

    for line in patch.splitlines():
        if line.startswith("@@"):
            # Example: @@ -10,0 +11,2 @@
            right = line.split("+", 1)[1].split(" ", 1)[0]
            start_text = right.split(",", 1)[0]
            line_no = int(start_text) - 1
            continue
        if line.startswith("+++ ") or line.startswith("--- "):
            continue
        if line.startswith("+"):
            line_no += 1
            added.append((line_no, line[1:]))
            continue
        if line.startswith(" "):
            line_no += 1

    return added


def read_index_file(repo_root: Path, rel_path: str) -> str:
    return run_git(repo_root, ["show", f":{rel_path}"])


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    lists_dir = repo_root / "lists"
    txt_files = sorted(p.relative_to(repo_root).as_posix() for p in lists_dir.glob("*.txt"))
    staged_files = get_staged_list_files(repo_root)

    if not staged_files:
        print("pre-commit validation passed (no staged lists/*.txt changes).")
        return 0

    errors: list[str] = []
    domains_to_files: dict[str, set[str]] = defaultdict(set)
    domain_locations: dict[str, list[str]] = defaultdict(list)
    networks: list[tuple[ipaddress._BaseNetwork, str, str]] = []
    new_domains: list[tuple[str, str]] = []
    new_networks: list[tuple[ipaddress._BaseNetwork, str]] = []

    for rel_path in txt_files:
        raw_lines = read_index_file(repo_root, rel_path).splitlines()
        file_name = Path(rel_path).name

        if rel_path in staged_files and len(raw_lines) > MAX_LINES_PER_FILE:
            errors.append(
                f"{rel_path}: {len(raw_lines)} lines (max {MAX_LINES_PER_FILE})"
            )

        for line_no, line in enumerate(raw_lines, start=1):
            value = line.strip().lower().rstrip(".")
            if not value or value.startswith("#"):
                continue

            net = parse_network(value)
            if net is not None:
                networks.append((net, file_name, f"{file_name}:{line_no}"))
                continue

            if is_domain(value):
                domains_to_files[value].add(file_name)
                domain_locations[value].append(f"{file_name}:{line_no}")
                continue

            if rel_path in staged_files:
                errors.append(
                    f"{rel_path}:{line_no}: invalid entry `{line.strip()}` "
                    "(expected domain or CIDR/IP)"
                )

    for rel_path in staged_files:
        file_name = Path(rel_path).name
        for line_no, added_line in get_staged_added_lines(repo_root, rel_path):
            value = added_line.strip().lower().rstrip(".")
            if not value or value.startswith("#"):
                continue

            net = parse_network(value)
            if net is not None:
                new_networks.append((net, f"{file_name}:{line_no}"))
                continue

            if is_domain(value):
                new_domains.append((value, f"{file_name}:{line_no}"))
                continue

            errors.append(
                f"{rel_path}:{line_no}: invalid added value `{added_line.strip()}` "
                "(expected domain or CIDR/IP)"
            )

    for domain, files in sorted(domains_to_files.items()):
        if len(files) > 1:
            new_locs = [loc for value, loc in new_domains if value == domain]
            if not new_locs:
                continue
            all_locations = ", ".join(sorted(domain_locations[domain]))
            added_locations = ", ".join(sorted(new_locs))
            errors.append(
                f"duplicate domain across files `{domain}`; added at [{added_locations}], "
                f"all occurrences [{all_locations}]"
            )

    all_domains = set(domains_to_files.keys())
    for domain, domain_loc in new_domains:
        labels = domain.split(".")
        for idx in range(1, len(labels) - 1):
            parent = ".".join(labels[idx:])
            if parent in all_domains:
                parent_locations = ", ".join(sorted(domain_locations[parent]))
                errors.append(
                    f"domain `{domain}` is narrower than existing `{parent}`; "
                    f"added at [{domain_loc}], parent at [{parent_locations}]"
                )
                break

    for net_new, loc_new in new_networks:
        for net_existing, _file_existing, loc_existing in networks:
            if net_new.version != net_existing.version:
                continue

            if loc_new == loc_existing:
                continue

            if net_new == net_existing:
                errors.append(
                    f"network `{net_new}` is duplicated; added at [{loc_new}], "
                    f"already present at [{loc_existing}]"
                )
                continue

            if net_new.subnet_of(net_existing):
                errors.append(
                    f"network `{net_new}` at [{loc_new}] is narrower than "
                    f"`{net_existing}` at [{loc_existing}]"
                )

    if errors:
        print("pre-commit validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print("pre-commit validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
