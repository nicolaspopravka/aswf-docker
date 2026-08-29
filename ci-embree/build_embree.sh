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
# Embree 3.13.2 declares its version as three SET() lines (no single
# "VERSION x.y.z" token) -- assert the expected components per line.
grep -m1 "SET(EMBREE_VERSION_MAJOR 3)" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
  | tee "$EVIDENCE_ROOT/embree-version-line.txt"
grep -m1 "SET(EMBREE_VERSION_MINOR 13)" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
  | tee -a "$EVIDENCE_ROOT/embree-version-line.txt"
grep -m1 "SET(EMBREE_VERSION_PATCH 2)" "$BUILD_ROOT/embree-src/CMakeLists.txt" \
  | tee -a "$EVIDENCE_ROOT/embree-version-line.txt"

cmake -S "$BUILD_ROOT/embree-src" -B "$BUILD_ROOT/embree-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$EMBREE_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DEMBREE_TUTORIALS=OFF \
  -DEMBREE_ISPC_SUPPORT=OFF \
  -DEMBREE_TBB_ROOT=/usr/local

cmake --build "$BUILD_ROOT/embree-build" -j"$(nproc)"
cmake --install "$BUILD_ROOT/embree-build"

test -f "$EMBREE_PREFIX/lib/libembree3.so"

cp "$BUILD_ROOT/embree-build/CMakeCache.txt" "$EVIDENCE_ROOT/Embree-CMakeCache.txt"
find "$EMBREE_PREFIX" -type f -print | sort \
  > "$EVIDENCE_ROOT/embree-install-manifest.txt"

ldd -r "$EMBREE_PREFIX/lib/libembree3.so" | tee "$EVIDENCE_ROOT/libembree3-ldd.txt"

{
  printf 'Embree tag: %s\n' "$EMBREE_TAG"
  printf 'Embree revision: %s\n' "$EMBREE_REVISION"
  printf 'Embree tarball sha256: %s\n' "$EMBREE_TARBALL_SHA256"
  printf 'Embree prefix: %s\n' "$EMBREE_PREFIX"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
  printf 'TBB: '
  ls /usr/local/lib/libtbb.so.* 2>/dev/null | head -1 || true
} > "$EVIDENCE_ROOT/source-revisions.txt"

rm -rf "$BUILD_ROOT"
