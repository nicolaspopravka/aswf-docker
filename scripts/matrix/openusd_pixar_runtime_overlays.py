#!/usr/bin/env python3

import argparse
import copy
import json
import re
import sys
from pathlib import Path


SCHEMA_VERSION = "openusd-pixar-runtime-overlays/v1"
EXPECTED_YEARS = [2023, 2024, 2025, 2026, 2027]
EXPECTED_PYTHON = {
    2023: "3.10.20",
    2024: "3.11.15",
    2025: "3.11.15",
    2026: "3.13.14",
    2027: "3.13.14",
}
EXPECTED_PYSIDE = {
    2023: None,
    2024: None,
    2025: "6.5.3",
    2026: "6.8.3",
    2027: "6.8.3",
}
EXPECTED_LOCK_PACKAGES = {
    "pyside6",
    "pyside6-addons",
    "pyside6-essentials",
    "shiboken6",
}
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
LOCK_RE = re.compile(
    r"^([A-Za-z0-9_-]+)==([0-9]+(?:\.[0-9]+)+) "
    r"--hash=sha256:([0-9a-f]{64})$"
)


class ValidationError(Exception):
    pass


def load_manifest(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"cannot read manifest {path}: {error}") from error
    if not isinstance(data, dict):
        raise ValidationError("manifest root must be an object")
    return data


def normalized_package(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def validate_lock(path: Path, version: str) -> None:
    try:
        lines = [
            line.strip()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    except OSError as error:
        raise ValidationError(f"cannot read lock file {path}: {error}") from error

    packages = set()
    hashes = set()
    for number, line in enumerate(lines, 1):
        match = LOCK_RE.fullmatch(line)
        if not match:
            raise ValidationError(f"{path}:{number}: malformed lock entry")
        package, observed_version, digest = match.groups()
        package = normalized_package(package)
        if observed_version != version:
            raise ValidationError(
                f"{path}:{number}: expected version {version}, got {observed_version}"
            )
        if package in packages:
            raise ValidationError(f"{path}:{number}: duplicate package {package}")
        if digest in hashes:
            raise ValidationError(f"{path}:{number}: duplicate wheel hash")
        packages.add(package)
        hashes.add(digest)

    if packages != EXPECTED_LOCK_PACKAGES:
        raise ValidationError(
            f"{path}: expected packages {sorted(EXPECTED_LOCK_PACKAGES)}, "
            f"got {sorted(packages)}"
        )


def validate_manifest(path: Path, data: dict) -> None:
    allowed_root = {
        "schema_version",
        "registry",
        "parent_workflow_revision",
        "entries",
    }
    if set(data) != allowed_root:
        raise ValidationError(
            f"manifest root keys must be exactly {sorted(allowed_root)}"
        )
    if data["schema_version"] != SCHEMA_VERSION:
        raise ValidationError(f"unexpected schema_version {data['schema_version']!r}")
    if data["registry"] != "ghcr.io/nicolaspopravka/openusd-build-paths":
        raise ValidationError("unexpected registry")
    revision = data["parent_workflow_revision"]
    if not isinstance(revision, str) or not COMMIT_RE.fullmatch(revision):
        raise ValidationError("parent_workflow_revision must be a 40-digit commit")

    entries = data["entries"]
    if not isinstance(entries, list) or len(entries) != 5:
        raise ValidationError("entries must contain exactly five objects")

    years = []
    names = set()
    digests = set()
    expected_entry_keys = {
        "name",
        "cy",
        "python_version",
        "parent_digest",
        "pyside_version",
        "pyside_lock",
    }
    for index, entry in enumerate(entries):
        field = f"entries[{index}]"
        if not isinstance(entry, dict) or set(entry) != expected_entry_keys:
            raise ValidationError(
                f"{field} keys must be exactly {sorted(expected_entry_keys)}"
            )
        year = entry["cy"]
        if year not in EXPECTED_YEARS:
            raise ValidationError(f"{field}.cy is not a requested matrix year")
        years.append(year)

        expected_name = f"pixar-cy{year}-runtime"
        if entry["name"] != expected_name:
            raise ValidationError(f"{field}.name must be {expected_name}")
        if entry["name"] in names:
            raise ValidationError(f"duplicate entry name {entry['name']}")
        names.add(entry["name"])

        if entry["python_version"] != EXPECTED_PYTHON[year]:
            raise ValidationError(
                f"{field}.python_version must be {EXPECTED_PYTHON[year]}"
            )
        digest = entry["parent_digest"]
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise ValidationError(f"{field}.parent_digest is not sha256")
        if digest in digests:
            raise ValidationError(f"duplicate parent digest {digest}")
        digests.add(digest)

        expected_pyside = EXPECTED_PYSIDE[year]
        if entry["pyside_version"] != expected_pyside:
            raise ValidationError(
                f"{field}.pyside_version must be {expected_pyside!r}"
            )
        lock_name = entry["pyside_lock"]
        if expected_pyside is None:
            if lock_name is not None:
                raise ValidationError(f"{field}.pyside_lock must be null")
        else:
            expected_lock = f"pyside6-{expected_pyside}-linux-x86_64.lock"
            if lock_name != expected_lock:
                raise ValidationError(f"{field}.pyside_lock must be {expected_lock}")
            validate_lock(path.parent / lock_name, expected_pyside)

    if years != EXPECTED_YEARS:
        raise ValidationError(f"entries must be ordered by CY: {EXPECTED_YEARS}")


def selected_matrix(data: dict, scope: str) -> dict:
    entries = data["entries"]
    if scope == "all":
        selected = entries
    elif scope == "pilot":
        selected = [entry for entry in entries if entry["cy"] == 2025]
    else:
        normalized = scope if scope.endswith("-runtime") else f"{scope}-runtime"
        selected = [entry for entry in entries if entry["name"] == normalized]
        if not selected:
            raise ValidationError(f"unknown scope {scope!r}")

    registry = data["registry"]
    revision = data["parent_workflow_revision"]
    result = []
    for original in selected:
        entry = copy.deepcopy(original)
        parent_tag = f"{registry}:pixar-cy{entry['cy']}-{revision}"
        entry["parent_image"] = f"{parent_tag}@{entry['parent_digest']}"
        entry["pyside_version"] = entry["pyside_version"] or "none"
        entry["pyside_lock"] = entry["pyside_lock"] or "none"
        result.append(entry)
    return {"include": result}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("openusd_pixar_runtime_overlays.json"),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    select = subparsers.add_parser("select")
    select.add_argument("--scope", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        data = load_manifest(args.manifest)
        validate_manifest(args.manifest, data)
        if args.command == "select":
            print(
                json.dumps(
                    selected_matrix(data, args.scope),
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
        else:
            print(f"valid: {args.manifest}")
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
