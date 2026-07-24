# OpenUSD build-path matrix images

The `Build OpenUSD build-path matrix images` workflow creates the ten
source-built OCI images required by the USD benchmark matrix:

- Pixar OpenUSD `build_scripts/build_usd.py` for CY2023 through CY2027.
- ASWF Docker `scripts/vfx/build_usd.sh` for CY2023 through CY2027.

It does not rebuild or copy the prebuilt `aswf/ci-vfxall` row.

Each Pixar job starts from the matching digest-pinned `aswf/ci-common`
toolchain image so `build_usd.py` constructs its own dependency stack under
`/opt/openusd`. Each ASWF-script job starts from the matching digest-pinned
`aswf/ci-usd` dependency image and installs under `/usr/local`. The harness
fails a Pixar job if the base exposes `ASWF_OPENUSD_VERSION`, then proves that
`usdrecord`, `usdcat`, the `pxr` Python package, and installed OpenUSD
libraries are absent. It selects the matching VFX Platform GCC toolset
explicitly, verifies source and script hashes, builds OpenUSD, verifies that
the runtime resolves from the intended install prefix, embeds the evidence
below `/opt/openusd-build-evidence`, and publishes the image to:

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
- Any exact matrix cell name, such as `pixar-cy2023`: retry only that cell
  without rebuilding successful images from the same batch.

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

ASWF's CY2024 helper downloads PR3159 at execution time. The harness reconstructs
the final PR diff from its immutable base and head commits, verifies its pinned
SHA-256, and interposes a narrow `curl` shim so the unchanged helper consumes
those verified bytes when it requests the live PR URL.

The stock ASWF helper runs an unversioned `pip3 install` and removes its source
and build directory after installation. The image records the pip inventory
before and after the helper and preserves the complete configure/build log; it
does not claim a surviving CMake cache for that path.
