#!/usr/bin/env python3
"""Generate the pinned OpenMoonRay/ASWF compatibility inventory."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
from typing import Any


KEY_DEPENDENCIES = (
    "boost",
    "cpython",
    "log4cplus",
    "lua",
    "materialx",
    "moonray",
    "onetbb",
    "opencolorio",
    "openexr",
    "openimagedenoise",
    "openimageio",
    "opensubdiv",
    "openusd",
)

PROJECT_NAMES = {
    "OpenColorIO": "opencolorio",
    "OpenEXR": "openexr",
    "OpenImageDenoise": "openimagedenoise",
    "OpenImageIO": "openimageio",
    "OpenSubdiv": "opensubdiv",
    "TBB": "onetbb",
    "USD": "openusd",
}


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout


def git_show(repo: Path, ref: str, path: str) -> str:
    return git(repo, "show", f"{ref}:{path}")


def verify_commit(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", f"{ref}^{{commit}}").strip()


def parse_profile(text: str) -> dict[str, str]:
    versions: dict[str, str] = {}
    pattern = re.compile(r"^([a-z0-9_-]+)/\*:\s+\1/([^@\s]+)@", re.MULTILINE)
    for name, version in pattern.findall(text):
        if name in KEY_DEPENDENCIES:
            versions[name] = version
    return versions


def version_from_external_project(block: str) -> str | None:
    comment = re.search(r"(?:GIT_TAG|URL)[^\n]*#\s*(?:v)?([0-9][^\s)]*)", block)
    if comment:
        return comment.group(1)
    url = re.search(r"\bURL\s+\S*?(?:v|oidn-|ispc-v)([0-9]+(?:\.[0-9]+)+)", block)
    if url:
        return url.group(1)
    return None


def parse_native_manifest(text: str) -> tuple[dict[str, str], list[dict[str, str]]]:
    versions: dict[str, str] = {}
    projects: list[dict[str, str]] = []
    starts = list(re.finditer(r"ExternalProject_Add\(\s*([A-Za-z0-9_]+)", text))
    for index, match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        block = text[match.start():end]
        name = match.group(1)
        repository = re.search(r"GIT_REPOSITORY\s+(\S+)", block)
        tag = re.search(r"GIT_TAG\s+(\S+)", block)
        url = re.search(r"\bURL\s+(\S+)", block)
        version = version_from_external_project(block)
        item = {"name": name}
        if repository:
            item["repository"] = repository.group(1)
        if tag:
            item["git_tag"] = tag.group(1)
        if url:
            item["url"] = url.group(1)
        if version:
            item["version"] = version
        projects.append(item)
        normalized = PROJECT_NAMES.get(name)
        if normalized and version:
            versions[normalized] = version
    return versions, projects


def parse_os_packages(text: str) -> list[dict[str, str]]:
    packages: list[dict[str, str]] = []
    for line in text.splitlines():
        if not line.lstrip().startswith("dnf install"):
            continue
        comment = line.partition("#")[2].strip()
        command = line.partition("#")[0].strip()
        packages.append({"command": command, "version_note": comment})
    return packages


def major(version: str | None) -> int | None:
    if not version:
        return None
    match = re.match(r"(\d+)", version)
    return int(match.group(1)) if match else None


def classify(
    candidate: dict[str, str],
    release: dict[str, Any],
    image_versions: dict[str, str],
    native_versions: dict[str, str],
    observed: dict[str, Any] | None,
) -> tuple[str, list[str]]:
    if observed:
        return observed["outcome"], [observed["finding"]]

    reasons: list[str] = []
    native_oidn = native_versions.get("openimagedenoise")
    image_oidn = image_versions.get("openimagedenoise")
    if major(native_oidn) != major(image_oidn):
        reasons.append(f"OIDN API family differs: native {native_oidn}, image {image_oidn}.")

    image_usd = image_versions.get("openusd", "")
    if release.get("legacy_ndr_plugins") and major(image_usd) is not None and major(image_usd) >= 26:
        reasons.append(f"OpenUSD {image_usd} removes legacy NDR APIs used by the pinned shader plugins.")

    if reasons:
        return "do-not-run", reasons

    exact_keys = ("openimagedenoise", "openusd", "onetbb", "opencolorio", "openexr", "openimageio", "opensubdiv")
    if all(key in native_versions and key in image_versions for key in exact_keys) and all(
        native_versions[key] == image_versions[key] for key in exact_keys
    ):
        return "run-exact", ["All comparable native dependency versions match the ASWF profile."]
    return "run-plausible", ["No known hard API conflict was found; dependency versions are not an exact native match."]


def render_markdown(data: dict[str, Any]) -> str:
    lines = [
        "# OpenMoonRay / ASWF compatibility inventory",
        "",
        "Generated from pinned OpenMoonRay commits and historical ASWF `ci-moonray` Git tags.",
        "Observed build results override static compatibility inference. This report authorizes no build dispatch.",
        "",
        "## Candidate decisions",
        "",
        "| Candidate | Intent | Outcome/gate | Key reason |",
        "|---|---|---|---|",
    ]
    for item in data["candidates"]:
        reason = " ".join(item["reasons"])
        lines.append(f'| `{item["id"]}` | {item["intent"]} | **{item["outcome"]}** | {reason} |')

    lines.extend(["", "## Dependency comparison", ""])
    for item in data["candidates"]:
        lines.extend([
            f'### `{item["id"]}`',
            "",
            "| Dependency | OpenMoonRay native | ASWF image |",
            "|---|---:|---:|",
        ])
        for name in KEY_DEPENDENCIES:
            native = item["native_versions"].get(name, "not fixed here")
            image = item["image_versions"].get(name, "not recorded")
            lines.append(f"| {name} | {native} | {image} |")
        lines.append("")

    lines.extend([
        "## Evidence and policy",
        "",
        "- `image-intended` means the annual ASWF profile names that OpenMoonRay version; it is not an upstream support guarantee.",
        "- `run-plausible` means static inspection found no known hard API conflict; Nicolas must still explicitly approve the run.",
        "- `do-not-run` means a known API-family conflict makes another Actions attempt unjustified under the no-source-patch rule.",
        "- The only successful image is the supplemented CY2025 / OpenMoonRay 2.34 candidate at `ghcr.io/nicolaspopravka/openmoonray-hydra@sha256:d7e3fa78882b68591d67d745bfb350912d363d7c7b77c74b5e0bb5f185f40dc8`.",
        "- No OpenMoonRay source patch, dependency replacement or plugin omission is permitted by this inventory.",
        "",
    ])
    return "\n".join(lines)


def generate(config: dict[str, Any], aswf_repo: Path, openmoonray_repo: Path) -> dict[str, Any]:
    releases: dict[str, Any] = {}
    for version, release in config["openmoonray_releases"].items():
        commit = verify_commit(openmoonray_repo, release["ref"])
        if commit != release["ref"]:
            raise SystemExit(f"OpenMoonRay ref mismatch for {version}: {commit}")
        cmake = git_show(openmoonray_repo, commit, "building/Rocky9/CMakeLists.txt")
        packages = git_show(openmoonray_repo, commit, "building/Rocky9/install_packages.sh")
        native_versions, projects = parse_native_manifest(cmake)
        releases[version] = {
            **release,
            "native_versions": native_versions,
            "external_projects": projects,
            "os_packages": parse_os_packages(packages),
            "submodules": [
                line
                for line in git(openmoonray_repo, "ls-tree", "-r", commit).strip().splitlines()
                if line.startswith("160000 commit ")
            ],
            "sources": [
                f"{commit}:building/Rocky9/CMakeLists.txt",
                f"{commit}:building/Rocky9/install_packages.sh",
            ],
        }

    images: dict[str, Any] = {}
    for year, image in config["aswf_images"].items():
        commit = verify_commit(aswf_repo, image["git_ref"])
        profile_path = f'packages/conan/settings/profiles/{image["profile"]}'
        versions = parse_profile(git_show(aswf_repo, commit, profile_path))
        images[year] = {
            **image,
            "commit": commit,
            "versions": versions,
            "sources": [
                f'{image["git_ref"]}:{profile_path}',
                f'{image["git_ref"]}:packages/conan/recipes/moonray/conanfile.py',
                f'{image["git_ref"]}:ci-moonray/image.yaml',
            ],
        }

    candidates: list[dict[str, Any]] = []
    observed_results = config["observed_results"]
    for candidate in config["candidates"]:
        release = releases[candidate["release"]]
        image = images[candidate["year"]]
        observed = observed_results.get(candidate["id"])
        intent = "image-intended" if image["versions"].get("moonray") == candidate["release"] else "experimental"
        outcome, reasons = classify(candidate, release, image["versions"], release["native_versions"], observed)
        candidates.append({
            **candidate,
            "intent": intent,
            "outcome": outcome,
            "reasons": reasons,
            "native_versions": release["native_versions"],
            "image_versions": image["versions"],
            "observed": observed,
        })

    return {
        "schema_version": config["schema_version"],
        "policy": {"dispatch_requires_human_review": True, "source_patches_allowed": False},
        "releases": releases,
        "images": images,
        "candidates": candidates,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--aswf-repo", type=Path, required=True)
    parser.add_argument("--openmoonray-repo", type=Path, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--markdown-output", type=Path, required=True)
    args = parser.parse_args()

    config = json.loads(args.input.read_text())
    data = generate(config, args.aswf_repo, args.openmoonray_repo)
    args.json_output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    args.markdown_output.write_text(render_markdown(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
