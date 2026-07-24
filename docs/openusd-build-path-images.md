# OpenUSD build-path matrix images

The `Build OpenUSD build-path matrix images` workflow creates the ten
source-built OCI images required by the USD benchmark matrix:

- Pixar OpenUSD `build_scripts/build_usd.py` for CY2023 through CY2027.
- ASWF Docker `scripts/vfx/build_usd.sh` for CY2023 through CY2027.

It does not rebuild or copy the prebuilt `aswf/ci-vfxall` row.

Every job starts from the exact linux/amd64 `aswf/ci-usd` digest recorded in
the workflow. The harness first proves that `usdrecord`, `usdcat`, the `pxr`
Python package, and installed OpenUSD libraries are absent. It then selects the
image's matching GCC toolset explicitly, verifies source and script hashes,
builds OpenUSD, verifies that the runtime resolves from the intended install
prefix, embeds the evidence below `/opt/openusd-build-evidence`, and publishes
the image to:

```text
ghcr.io/nicolaspopravka/openusd-build-paths:<path>-cy<year>-<workflow-commit>
```

The published digest, Docker build log, image inspection, build inputs,
configure/build log, compiler identity, CMake caches when retained, install
inventory, and runtime dependency inventory are also uploaded as a GitHub
Actions artifact. Runtime checksum paths are relative to the extracted
evidence directory so `sha256sum --check runtime/evidence-sha256.txt` works
after download.

## Dispatch order

The workflow has three scopes:

- `pilot`: build and publish the two CY2025 images.
- `remaining`: build and publish the other eight images after the pilot is
  accepted.
- `all`: rebuild all ten only when a new immutable workflow revision requires
  it.

The intended sequence is `pilot`, evidence audit, then `remaining`. GPU
rendering is a separate phase and must use the exact published digest rather
than the mutable tag.

## Local validation

Run:

```bash
bash scripts/matrix/validate_openusd_build_path_images.sh
```

This verifies the pinned upstream ASWF helper hash, checks shell syntax,
checks the ten workflow entries and GHCR permissions, and dry-runs both
CY2025 build-path input sets. It does not download an image, build OpenUSD,
push a package, or launch paid compute.

## Deliberate exceptions

OpenUSD 24.08's distributed Pixar script names a retired Boost JFrog URL. The
harness verifies the unmodified script hash, changes only that URL to the
same-content `archives.boost.io` endpoint, and records the executed script,
its hash, and the exact diff.

ASWF's CY2024 helper downloads PR3159 at execution time. The harness downloads
that patch, verifies its pinned SHA-256, and interposes a narrow `curl` shim so
the unchanged helper consumes the verified bytes.

The stock ASWF helper runs an unversioned `pip3 install` and removes its source
and build directory after installation. The image records the pip inventory
before and after the helper and preserves the complete configure/build log; it
does not claim a surviving CMake cache for that path.
