#!/usr/bin/env bash

set -euxo pipefail

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-build-evidence"

: "${CYCLES_TAG:?CYCLES_TAG is required}"
: "${CYCLES_REVISION:?CYCLES_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"
: "${TBB_ABI:?TBB_ABI is required}"

source /opt/rh/gcc-toolset-11/enable
mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"
test "$(git -C "$BUILD_ROOT/cycles" rev-parse HEAD)" = "$CYCLES_REVISION"
test -z "$(git -C "$BUILD_ROOT/cycles" status --short)"

(
  cd "$BUILD_ROOT/cycles"
  rm -rf lib/linux_x64
  mkdir -p lib
  cp -a /opt/cycles-dependencies lib/linux_x64
  make update
  test "$(git rev-parse HEAD)" = "$CYCLES_REVISION"
  test "$(git -C lib/linux_x64 rev-parse HEAD)" = "$CYCLES_LIB_REVISION"
  cmake -B ./build \
    -DPXR_ROOT=/opt/usd \
    -DCMAKE_PROJECT_INCLUDE=/usr/local/share/cycles/import_openusd_dependencies.cmake
  make
  test -x install/cycles
  test -f install/hydra/hdCycles.so
  test -f install/hydra/plugInfo.json
  cp build/CMakeCache.txt "$EVIDENCE_ROOT/Cycles-CMakeCache.txt"
  cp -a install /opt/cycles
)

LD_LIBRARY_PATH="/opt/cycles/lib:/opt/cycles-dependencies/tbb/lib:/opt/usd/lib:/opt/usd/lib64:${LD_LIBRARY_PATH:-}" \
  ldd -r /opt/cycles/hydra/hdCycles.so | tee "$EVIDENCE_ROOT/hdCycles-ldd.txt"
! grep -Eq 'not found|undefined symbol' "$EVIDENCE_ROOT/hdCycles-ldd.txt"

if [[ "$TBB_ABI" == classic ]]; then
  grep -q 'libtbb.so.2' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
  ! grep -q 'libtbb.so.12' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
else
  grep -q 'libtbb.so.12' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
  ! grep -q 'libtbb.so.2 ' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
fi

readelf -d /opt/cycles/hydra/hdCycles.so > "$EVIDENCE_ROOT/hdCycles-dynamic.txt"
find /opt/cycles -type f -print | sort > "$EVIDENCE_ROOT/cycles-install-manifest.txt"
rm -rf /opt/usd/src "$BUILD_ROOT"
