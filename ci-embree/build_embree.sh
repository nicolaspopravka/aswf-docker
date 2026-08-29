#!/usr/bin/env bash
set -euxo pipefail

# Build Embree v3.13.2 from the pinned source tarball into /opt/embree.
#
# hdEmbree's FindEmbree module (OpenUSD 25.05) hardcodes libembree3.so /
# libembree3.dylib, which pins the 3.x series (3.13.2 is the final 3.x
# release line usable here).  ISPC and the tutorials are off: the delegate
# consumes Embree through the C API only.  TBB comes from the base image
# (oneTBB 2021.x via conan, TBBConfig at /usr/local/lib/cmake/TBB); Embree
# 3.13 supports oneTBB.  If TBB detection ever fails for a given year, the
# honest fallback is EMBREE_TBB=OFF (single-threaded BVH build) recorded as
# a benchmark finding -- not a silent patch.

readonly EMBREE_URL="https://github.com/RenderKit/embree/archive/refs/tags/${EMBREE_TAG}.tar.gz"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/embree-build-evidence"
readonly EMBREE_PREFIX="/opt/embree"

: "${EMBREE_TAG:?EMBREE_TAG is required}"
: "${EMBREE_REVISION:?EMBREE_REVISION is required}"
: "${EMBREE_TARBALL_SHA256:?EMBREE_TARBALL_SHA256 is required}"

# Embree 3.x pairs with a vendored legacy TBB 2020.3.1 (its tasking uses
# tbb::task_scheduler_init, which oneTBB 2021 removed): the exact
# combination Pixar's build_usd.py InstallTBB_Linux ships.  Sonames
# libtbb.so.2 (vendored) and libtbb.so.12 (image oneTBB for pxr) coexist.
if [[ "${EMBREE_TAG#v}" == 3.* ]]; then
  : "${TBB_TAG:?TBB_TAG is required for the Embree 3.x pairing}"
  : "${TBB_REVISION:?TBB_REVISION is required for the Embree 3.x pairing}"
  : "${TBB_TARBALL_SHA256:?TBB_TARBALL_SHA256 is required for the Embree 3.x pairing}"
fi

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

tarball="$BUILD_ROOT/embree-${EMBREE_TAG}.tar.gz"
curl -fsSL --retry 5 -o "$tarball" "$EMBREE_URL"
echo "${EMBREE_TARBALL_SHA256}  ${tarball}" | sha256sum --check --strict \
  | tee "$EVIDENCE_ROOT/embree-sha256-check.txt"

mkdir -p "$BUILD_ROOT/embree-src"
tar -xzf "$tarball" --strip-components=1 -C "$BUILD_ROOT/embree-src"
# Embree declares its version as three SET() lines (no single
# "VERSION x.y.z" token) -- assert the components derived from the tag
# (3.x for OpenUSD <= 25.05, 4.x for 26.03+, whose FindEmbree hardcodes
# libembree4).
readonly EMBREE_VERSION="${EMBREE_TAG#v}"
IFS='.' read -r EMBREE_VMAJOR EMBREE_VMINOR EMBREE_VPATCH <<< "$EMBREE_VERSION"
grep -m1 "SET(EMBREE_VERSION_MAJOR ${EMBREE_VMAJOR})" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
  | tee "$EVIDENCE_ROOT/embree-version-line.txt"
grep -m1 "SET(EMBREE_VERSION_MINOR ${EMBREE_VMINOR})" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
  | tee -a "$EVIDENCE_ROOT/embree-version-line.txt"
grep -m1 "SET(EMBREE_VERSION_PATCH ${EMBREE_VPATCH})" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
  | tee -a "$EVIDENCE_ROOT/embree-version-line.txt"

# --- vendored legacy TBB for the Embree 3.x pairing -------------------------
EMBREE_TBB_ROOT=/usr/local
TBB_STAGE=""
if [[ "$EMBREE_VMAJOR" == "3" ]]; then
  tbb_tarball="$BUILD_ROOT/tbb-${TBB_TAG}.tar.gz"
  curl -fsSL --retry 5 -o "$tbb_tarball" \
    "https://github.com/oneapi-src/oneTBB/archive/refs/tags/${TBB_TAG}.tar.gz"
  echo "${TBB_TARBALL_SHA256}  ${tbb_tarball}" | sha256sum --check --strict \
    | tee "$EVIDENCE_ROOT/tbb-sha256-check.txt"

  mkdir -p "$BUILD_ROOT/tbb-src"
  tar -xzf "$tbb_tarball" --strip-components=1 -C "$BUILD_ROOT/tbb-src"
  make -C "$BUILD_ROOT/tbb-src" -j"$(nproc)" tbb tbbmalloc

  TBB_STAGE="$BUILD_ROOT/tbb-stage"
  mkdir -p "$TBB_STAGE/include" "$TBB_STAGE/lib"
  cp -a "$BUILD_ROOT/tbb-src/include/tbb" "$TBB_STAGE/include/"
  cp -a "$BUILD_ROOT/tbb-src/build/"*_release/libtbb*.so.* "$TBB_STAGE/lib/"
  # TBB 2020's make emits only versioned sonames; find_library(tbb) needs
  # the unversioned dev symlink or it falls through to the image's oneTBB
  # (legacy symbols undefined at link -- run 33260052470 CY2025).
  for l in libtbb libtbbmalloc libtbbmalloc_proxy; do
    ln -sf "$l.so.2" "$TBB_STAGE/lib/$l.so"
  done
  test -f "$TBB_STAGE/include/tbb/task_scheduler_init.h"
  test -e "$TBB_STAGE/lib/libtbb.so.2"
  test -e "$TBB_STAGE/lib/libtbb.so"
  find "$TBB_STAGE" -type f -o -type l -print | sort \
    > "$EVIDENCE_ROOT/tbb-stage-manifest.txt"
  EMBREE_TBB_ROOT="$TBB_STAGE"
fi

cmake -S "$BUILD_ROOT/embree-src" -B "$BUILD_ROOT/embree-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$EMBREE_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DEMBREE_TUTORIALS=OFF \
  -DEMBREE_ISPC_SUPPORT=OFF \
  -DEMBREE_TBB_ROOT="$EMBREE_TBB_ROOT"

cmake --build "$BUILD_ROOT/embree-build" -j"$(nproc)"
cmake --install "$BUILD_ROOT/embree-build"

# Ship the vendored legacy TBB next to libembree3 so hdEmbree's RUNPATH
# (/opt/embree/lib) covers it at runtime.
if [[ -n "$TBB_STAGE" ]]; then
  cp -a "$TBB_STAGE"/lib/libtbb*.so.* "$EMBREE_PREFIX/lib/"
fi

test -e "$EMBREE_PREFIX/lib/libembree3.so" || test -e "$EMBREE_PREFIX/lib/libembree4.so"

cp "$BUILD_ROOT/embree-build/CMakeCache.txt" "$EVIDENCE_ROOT/Embree-CMakeCache.txt"
find "$EMBREE_PREFIX" -type f -print | sort \
  > "$EVIDENCE_ROOT/embree-install-manifest.txt"

ldd -r "$EMBREE_PREFIX"/lib/libembree*.so | tee -a "$EVIDENCE_ROOT/libembree-ldd.txt"

{
  printf 'Embree tag: %s\n' "$EMBREE_TAG"
  printf 'Embree revision: %s\n' "$EMBREE_REVISION"
  printf 'Embree tarball sha256: %s\n' "$EMBREE_TARBALL_SHA256"
  printf 'Embree prefix: %s\n' "$EMBREE_PREFIX"
  printf 'TBB pairing: %s\n' \
    "$([[ "$EMBREE_VMAJOR" == "3" ]] && printf 'vendored %s (build_usd.py InstallTBB_Linux)' "$TBB_TAG" || printf 'image oneTBB')"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
  printf 'Image TBB: '
  ls /usr/local/lib/libtbb.so.* 2>/dev/null | head -1 || true
} > "$EVIDENCE_ROOT/source-revisions.txt"

rm -rf "$BUILD_ROOT"
