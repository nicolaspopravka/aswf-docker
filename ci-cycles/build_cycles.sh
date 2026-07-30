#!/usr/bin/env bash

set -euxo pipefail

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-build-evidence"

: "${CYCLES_TAG:?CYCLES_TAG is required}"
: "${CYCLES_REVISION:?CYCLES_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"

source /opt/rh/gcc-toolset-14/enable

mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

test -x /opt/usd/bin/usdrecord
test -d /opt/usd/lib/python/pxr
test -e /opt/usd/lib/libtbb.so.12
if find /opt/usd/lib -maxdepth 1 -name 'libtbb.so.2*' -print -quit | grep -q .; then
  echo "Classic TBB unexpectedly present in the OpenUSD prefix" >&2
  exit 1
fi

git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"
test "$(git -C "$BUILD_ROOT/cycles" rev-parse HEAD)" = "$CYCLES_REVISION"

(
  cd "$BUILD_ROOT/cycles"
  rm -rf lib/linux_x64
  mkdir -p lib
  cp -a /opt/cycles-dependencies lib/linux_x64
  make update

  test "$(git -C lib/linux_x64 rev-parse HEAD)" = "$CYCLES_LIB_REVISION"

  file lib/linux_x64/zstd/lib/libzstd.a |
    tee "$EVIDENCE_ROOT/cycles-zstd-file.txt"
  ar t lib/linux_x64/zstd/lib/libzstd.a \
    > "$EVIDENCE_ROOT/cycles-zstd-members.txt"
  test -s "$EVIDENCE_ROOT/cycles-zstd-members.txt"

  cmake -B ./build -DPXR_ROOT=/opt/usd
  make

  test -f install/hydra/hdCycles.so
  test -f install/hydra/plugInfo.json
  test -d install/lib
  cp build/CMakeCache.txt "$EVIDENCE_ROOT/Cycles-CMakeCache.txt"
  cp lib/linux_x64/deps.md "$EVIDENCE_ROOT/cycles-dependencies.md"
  cp -a install /opt/cycles
)

{
  printf 'Cycles tag: %s\n' "$CYCLES_TAG"
  printf 'Cycles revision: %s\n' "$CYCLES_REVISION"
  printf 'Cycles Linux libraries revision: %s\n' "$CYCLES_LIB_REVISION"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
  printf 'Python: '
  python3 --version
} > "$EVIDENCE_ROOT/source-revisions.txt"

LD_LIBRARY_PATH="/opt/cycles/lib:/opt/usd/lib:${LD_LIBRARY_PATH:-}" \
  ldd /opt/cycles/hydra/hdCycles.so \
  | tee "$EVIDENCE_ROOT/hdCycles-ldd.txt"
if grep -q 'not found' "$EVIDENCE_ROOT/hdCycles-ldd.txt"; then
  exit 1
fi

readelf -d /opt/cycles/hydra/hdCycles.so \
  > "$EVIDENCE_ROOT/hdCycles-dynamic.txt"
find /opt/usd/lib -maxdepth 1 -type f -name 'libusd*.so' -print |
  sort > "$EVIDENCE_ROOT/openusd-shared-libraries.txt"
find /opt/cycles -type f -print | sort \
  > "$EVIDENCE_ROOT/cycles-install-manifest.txt"
find /opt/usd -type f -print | sort \
  > "$EVIDENCE_ROOT/openusd-install-manifest.txt"

rm -rf /opt/usd/src "$BUILD_ROOT"
