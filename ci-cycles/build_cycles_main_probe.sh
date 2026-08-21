#!/usr/bin/env bash
# Build blender/cycles main (post PR #75/#76) with only the UpdateConnections
# diagnostics patch applied, for the upstream-PR validation probe.

set -euxo pipefail

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-build-evidence"

: "${CYCLES_REVISION:?CYCLES_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"

source "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable"
mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

git clone --branch main --depth 50 "$CYCLES_URL" "$BUILD_ROOT/cycles"
git -C "$BUILD_ROOT/cycles" checkout --detach "$CYCLES_REVISION"
test "$(git -C "$BUILD_ROOT/cycles" rev-parse HEAD)" = "$CYCLES_REVISION"

git -C "$BUILD_ROOT/cycles" apply --check \
  /usr/local/share/cycles-updateconnections.patch
git -C "$BUILD_ROOT/cycles" apply \
  /usr/local/share/cycles-updateconnections.patch
git -C "$BUILD_ROOT/cycles" diff --check
git -C "$BUILD_ROOT/cycles" diff > "$EVIDENCE_ROOT/cycles-source.patch"

(
  cd "$BUILD_ROOT/cycles"
  rm -rf lib/linux_x64
  mkdir -p lib
  cp -a /opt/cycles-dependencies lib/linux_x64
  make update
  test "$(git -C lib/linux_x64 rev-parse HEAD)" = "$CYCLES_LIB_REVISION"
  test "$(git rev-parse HEAD)" = "$CYCLES_REVISION"
  cmake -B ./build \
    -DPXR_ROOT=/opt/usd \
    -DOPTIX_ROOT_DIR=/usr/local/NVIDIA-OptiX-SDK-8.0.0 \
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

grep -q 'libtbb.so.12' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
! grep -q 'libtbb.so.2 ' "$EVIDENCE_ROOT/hdCycles-ldd.txt"

readelf -d /opt/cycles/hydra/hdCycles.so > "$EVIDENCE_ROOT/hdCycles-dynamic.txt"
find /opt/cycles -type f -print | sort > "$EVIDENCE_ROOT/cycles-install-manifest.txt"
rm -rf /opt/usd/src "$BUILD_ROOT"
