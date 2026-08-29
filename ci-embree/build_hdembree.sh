#!/usr/bin/env bash
set -euxo pipefail

# Build hdEmbree as an external pxr consumer of the image's prebuilt OpenUSD
# (hdCycles pattern): compile the upstream hdEmbree sources from a pinned
# OpenUSD checkout against the installed pxrConfig, then install a
# self-contained delegate tree at /opt/hdembree/hydra.
#
# One USD build per image is a hard requirement: no second prefix is built;
# this script consumes whatever OpenUSD the base image ships.  If a hidden
# codegen dependency ever blocks the consumer build for a given year, the
# second-prefix fallback is an explicit decision point for Nicolas, never
# automatic (PLANS.md Phase 35a).

readonly OPENUSD_URL="https://github.com/PixarAnimationStudios/OpenUSD.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/hdembree-build-evidence"
readonly USD_PREFIX="/usr/local"
readonly CONSUMER_DIR="/usr/local/share/hdembree-consumer"
readonly INSTALL_PREFIX="/opt/hdembree"

: "${OPENUSD_TAG:?OPENUSD_TAG is required}"
: "${OPENUSD_REVISION:?OPENUSD_REVISION is required}"

if [[ -n "${ASWF_DTS_VERSION:-}" && -e "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable" ]]; then
  # shellcheck disable=SC1090
  source "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable"
else
  toolset="$(find /opt/rh -maxdepth 1 -type d -name 'gcc-toolset-*' | sort -V | tail -1)"
  if [[ -n "$toolset" ]]; then
    # shellcheck disable=SC1090
    source "$toolset/enable"
  fi
fi

mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

# --- verify the pxr installation we are consuming --------------------------
# The conan OpenUSD on the ASWF images installs pxrConfig.cmake directly at
# /usr/local (verified on ci-vfxall:2025); older years may differ -- fail
# loudly here so the per-year adjustment is explicit.
if [[ ! -f "$USD_PREFIX/pxrConfig.cmake" ]]; then
  echo "ERROR: pxrConfig.cmake not at $USD_PREFIX/pxrConfig.cmake" >&2
  echo "       adjust the pxr_DIR for this year's base image" >&2
  exit 1
fi
test -x "$USD_PREFIX/bin/usdrecord"
test -d "$USD_PREFIX/lib/python/pxr"
PYTHONPATH="$USD_PREFIX/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -c 'from pxr import Usd; print(Usd.GetVersion())' \
  | tee "$EVIDENCE_ROOT/openusd-version.txt"

find "$USD_PREFIX/lib" -maxdepth 1 -name 'libusd_*.so*' -printf '%f\n' | sort \
  > "$EVIDENCE_ROOT/openusd-libraries.txt"
printf 'Split-linkage libusd_*.so count: %s\n' \
  "$(wc -l < "$EVIDENCE_ROOT/openusd-libraries.txt")"

# --- pinned OpenUSD checkout (sources pristine) -----------------------------
command -v git >/dev/null 2>&1 || dnf install -y git
git clone --branch "$OPENUSD_TAG" --depth 1 "$OPENUSD_URL" "$BUILD_ROOT/openusd"
test "$(git -C "$BUILD_ROOT/openusd" rev-parse HEAD)" = "$OPENUSD_REVISION"
test -z "$(git -C "$BUILD_ROOT/openusd" status --short)"
git -C "$BUILD_ROOT/openusd" diff > "$EVIDENCE_ROOT/openusd-applied.patch"
test ! -s "$EVIDENCE_ROOT/openusd-applied.patch"

readonly HDEMBREE_SOURCE_DIR="$BUILD_ROOT/openusd/pxr/imaging/plugin/hdEmbree"
if [[ ! -d "$HDEMBREE_SOURCE_DIR" ]]; then
  echo "ERROR: hdEmbree sources not at $HDEMBREE_SOURCE_DIR" >&2
  echo "       verify the in-tree location for this year's OpenUSD" >&2
  exit 1
fi
ls "$HDEMBREE_SOURCE_DIR" | tee "$EVIDENCE_ROOT/hdembree-source-listing.txt"

# --- consumer build ----------------------------------------------------------
cmake -S "$CONSUMER_DIR" -B "$BUILD_ROOT/hdembree-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
  -Dpxr_DIR="$USD_PREFIX" \
  -DHDEMBREE_SOURCE_DIR="$HDEMBREE_SOURCE_DIR" \
  -DEMBREE_ROOT=/opt/embree \
  -DCMAKE_INSTALL_RPATH=/opt/embree/lib

cmake --build "$BUILD_ROOT/hdembree-build" -j"$(nproc)"
cmake --install "$BUILD_ROOT/hdembree-build"

# --- gates -------------------------------------------------------------------
test -f "$INSTALL_PREFIX/hydra/hdEmbree.so"
test -f "$INSTALL_PREFIX/hydra/plugInfo.json"
test -f "$INSTALL_PREFIX/hydra/hdEmbree/resources/plugInfo.json"
# token substitution completed
! grep -q "@PLUG_INFO" "$INSTALL_PREFIX/hydra/hdEmbree/resources/plugInfo.json"
grep -q '"Embree"' "$INSTALL_PREFIX/hydra/hdEmbree/resources/plugInfo.json"
grep -q '"Includes"' "$INSTALL_PREFIX/hydra/plugInfo.json"

LD_LIBRARY_PATH="/opt/embree/lib:$USD_PREFIX/lib:$USD_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  ldd -r "$INSTALL_PREFIX/hydra/hdEmbree.so" | tee "$EVIDENCE_ROOT/hdEmbree-ldd.txt"
! grep -Eq 'not found|undefined symbol' "$EVIDENCE_ROOT/hdEmbree-ldd.txt"
grep -q 'libembree3' "$EVIDENCE_ROOT/hdEmbree-ldd.txt"

# The TBB soname hdEmbree links must equal the one the installed pxr libs
# use (two TBBs in one process would be fatal).  Read the expectation from
# the installed stack instead of hardcoding a year-specific soname.
pxr_tbb_soname="$(ldd "$USD_PREFIX/lib/libusd_work.so" \
  | sed -n 's/.*\(libtbb\.so\.[0-9]*\).*/\1/p' | head -1)"
printf 'pxr TBB soname: %s\n' "$pxr_tbb_soname" \
  | tee "$EVIDENCE_ROOT/pxr-tbb-soname.txt"
test -n "$pxr_tbb_soname"
grep -q "$pxr_tbb_soname" "$EVIDENCE_ROOT/hdEmbree-ldd.txt"
! grep -oE 'libtbb\.so\.[0-9]+' "$EVIDENCE_ROOT/hdEmbree-ldd.txt" \
  | sort -u | grep -qv "^${pxr_tbb_soname}$"

readelf -d "$INSTALL_PREFIX/hydra/hdEmbree.so" | tee "$EVIDENCE_ROOT/hdEmbree-dynamic.txt"
grep -q "/opt/embree/lib" "$EVIDENCE_ROOT/hdEmbree-dynamic.txt"

cp "$BUILD_ROOT/hdembree-build/CMakeCache.txt" "$EVIDENCE_ROOT/HdEmbree-CMakeCache.txt"
find "$INSTALL_PREFIX" -type f -print | sort \
  > "$EVIDENCE_ROOT/hdembree-install-manifest.txt"

{
  printf 'OpenUSD tag: %s\n' "$OPENUSD_TAG"
  printf 'OpenUSD revision: %s\n' "$OPENUSD_REVISION"
  printf 'OpenUSD prefix: %s\n' "$USD_PREFIX"
  printf 'hdEmbree install prefix: %s\n' "$INSTALL_PREFIX"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
} > "$EVIDENCE_ROOT/source-revisions.txt"

rm -rf "$BUILD_ROOT"
