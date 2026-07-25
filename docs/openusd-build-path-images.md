# OpenUSD build-path matrix images

The `Build OpenUSD build-path matrix images` workflow creates the ten
source-built OCI images required by the USD benchmark matrix:

- Pixar OpenUSD `build_scripts/build_usd.py` for CY2023 through CY2027.
- ASWF Docker `scripts/vfx/build_usd.sh` for CY2023 through CY2027.

It does not rebuild or copy the prebuilt `aswf/ci-vfxall` row.

Each Pixar job starts from the matching digest-pinned `aswf/ci-common`
toolchain image so `build_usd.py` constructs its own dependency stack under
`/usr/local`. Each ASWF-script job starts from the matching digest-pinned
`aswf/ci-usd` dependency image and also installs under `/usr/local`. The harness
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

## Pixar runtime overlays

The accepted Pixar images intentionally install exact VFX Platform CPython
with `--with-ensurepip=no` and build OpenUSD with `--no-usdview`. This keeps
the `build_usd.py` dependency boundary clean, but the benchmark launcher needs
an installed `pip` to install Rez. The established CY2025-CY2027 EGL wrapper
also imports `PySide6.QtWidgets.QApplication`; the CY2023-CY2024 wrappers do
not.

The separate `Build OpenUSD Pixar runtime overlays` workflow derives thin
runtime images from the accepted tag-plus-digest Pixar parents without
rebuilding or changing OpenUSD. All five overlays install pip only from the
CPython-bundled, locally hashed `ensurepip` wheels. CY2025 additionally
installs hash-locked PySide6 6.5.3, and CY2026-CY2027 install hash-locked
PySide6 6.8.3. Those versions are within their matching VFX Platform `6.5.x`
and `6.8.x` families. CY2023-CY2024 install no PySide because their
established wrappers require none.

Each overlay proves that the parent image is the accepted immutable digest,
records the pip and PySide inputs, and compares hashes of the installed
OpenUSD libraries, tools, plugin metadata, and `pxr` package before and after
the runtime addition. Any OpenUSD change fails the build. Runtime evidence is
embedded below `/opt/openusd-runtime-evidence` with portable checksums and is
uploaded with the image inspection and immutable published digest.

Validate and dry-run the matrix without building or publishing:

```bash
bash scripts/matrix/validate_openusd_pixar_runtime_overlays.sh
python3 scripts/matrix/openusd_pixar_runtime_overlays.py select --scope pilot
python3 scripts/matrix/openusd_pixar_runtime_overlays.py select --scope all
```

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
