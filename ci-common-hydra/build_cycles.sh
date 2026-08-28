#!/usr/bin/env bash

set -euxo pipefail

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-build-evidence"
readonly USD_PREFIX="/usr/local"
readonly OPTIX_ROOT="/usr/local/NVIDIA-OptiX-SDK-${ASWF_OPTIX_VERSION}"

: "${CYCLES_TAG:?CYCLES_TAG is required}"
: "${CYCLES_REVISION:?CYCLES_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"

if [[ -n "${ASWF_DTS_VERSION:-}" && -e "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable" ]]; then
  # shellcheck disable=SC1090
  source "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable"
else
  toolset="$(find /opt/rh -maxdepth 1 -type d -name 'gcc-toolset-*' | sort -V | tail -1)"
  test -n "$toolset"
  # shellcheck disable=SC1090
  source "$toolset/enable"
fi

mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

dnf install -y git git-lfs glew-devel mesa-libEGL-devel mesa-libGL-devel mesa-libOSMesa-devel patchelf
dnf clean all
git lfs install --skip-repo

test -x "$USD_PREFIX/bin/usdrecord"
test -d "$USD_PREFIX/lib/python/pxr"
test -x /usr/local/cuda/bin/nvcc
test -f "$OPTIX_ROOT/include/optix.h"
test "${ASWF_CUDA_VERSION}" = "12.6.3"
test "${ASWF_OPTIX_VERSION}" = "8.0.0"

PYTHONPATH="$USD_PREFIX/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -c 'from pxr import Usd; v = Usd.GetVersion(); print(v); assert v == (0, 25, 5)' \
  | tee "$EVIDENCE_ROOT/openusd-version.txt"

git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"
test "$(git -C "$BUILD_ROOT/cycles" rev-parse HEAD)" = "$CYCLES_REVISION"
test -z "$(git -C "$BUILD_ROOT/cycles" status --short)"

(
  cd "$BUILD_ROOT/cycles"
  rm -rf lib/linux_x64
  mkdir -p lib
  cp -a /opt/cycles-dependencies lib/linux_x64

  test "$(git -C lib/linux_x64 rev-parse HEAD)" = "$CYCLES_LIB_REVISION"
  test -z "$(git status --short)"

  cmake -B ./build \
    -DPXR_ROOT="$USD_PREFIX" \
    -DOPTIX_ROOT_DIR="$OPTIX_ROOT" \
    -DCUDAToolkit_ROOT=/usr/local/cuda \
    -DWITH_CYCLES_DEVICE_CUDA=ON \
    -DWITH_CYCLES_DEVICE_OPTIX=ON \
    -DWITH_CYCLES_CUDA_BINARIES=ON \
    -DCYCLES_CUDA_BINARIES_ARCH='sm_89;compute_75' \
    -DWITH_CUDA_DYNLOAD=ON \
    -DWITH_CYCLES_HYDRA_RENDER_DELEGATE=ON
  cmake --build ./build --parallel "$(nproc)"

  test -f install/hydra/hdCycles.so
  test -f install/hydra/plugInfo.json
  test -f install/lib/kernel_sm_89.cubin.zst
  test -f install/lib/kernel_compute_75.ptx.zst
  test -f install/lib/kernel_optix.ptx.zst
  cp -a lib/linux_x64/tbb/lib/libtbb.so* install/lib/
  patchelf --set-rpath '$ORIGIN/../lib' install/hydra/hdCycles.so
  cp build/CMakeCache.txt "$EVIDENCE_ROOT/Cycles-CMakeCache.txt"
  cp lib/linux_x64/deps.md "$EVIDENCE_ROOT/cycles-dependencies.md"
  cp -a install /opt/cycles
)

grep -Fx 'WITH_CYCLES_DEVICE_CUDA:BOOL=ON' "$EVIDENCE_ROOT/Cycles-CMakeCache.txt"
grep -Fx 'WITH_CYCLES_DEVICE_OPTIX:BOOL=ON' "$EVIDENCE_ROOT/Cycles-CMakeCache.txt"
grep -Fx 'WITH_CYCLES_CUDA_BINARIES:BOOL=ON' "$EVIDENCE_ROOT/Cycles-CMakeCache.txt"
grep -Fx 'CYCLES_CUDA_BINARIES_ARCH:STRING=sm_89;compute_75' "$EVIDENCE_ROOT/Cycles-CMakeCache.txt"

{
  printf 'Cycles tag: %s\n' "$CYCLES_TAG"
  printf 'Cycles revision: %s\n' "$CYCLES_REVISION"
  printf 'Cycles Linux libraries revision: %s\n' "$CYCLES_LIB_REVISION"
  printf 'OpenUSD prefix: %s\n' "$USD_PREFIX"
  printf 'CUDA version: %s\n' "$ASWF_CUDA_VERSION"
  printf 'OptiX root: %s\n' "$OPTIX_ROOT"
  gcc --version | head -1
  cmake --version | head -1
  python3 --version
} > "$EVIDENCE_ROOT/source-revisions.txt"

ldd -r /opt/cycles/hydra/hdCycles.so \
  | tee "$EVIDENCE_ROOT/hdCycles-ldd.txt"
! grep -Eq 'not found|undefined symbol' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
grep -q 'libtbb.so.12' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
! grep -q 'libtbb.so.2 ' "$EVIDENCE_ROOT/hdCycles-ldd.txt"

readelf -d /opt/cycles/hydra/hdCycles.so \
  > "$EVIDENCE_ROOT/hdCycles-dynamic.txt"
grep -Fq '$ORIGIN/../lib' "$EVIDENCE_ROOT/hdCycles-dynamic.txt"
find /opt/cycles -type f -print | sort \
  > "$EVIDENCE_ROOT/cycles-install-manifest.txt"

rm -rf "$BUILD_ROOT"
