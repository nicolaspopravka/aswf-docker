#!/usr/bin/env bash
set -euxo pipefail

readonly CYCLES_URL="https://projects.blender.org/blender/cycles.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-build-evidence"
readonly USD_PREFIX="/usr/local"

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

dnf install -y git glew-devel mesa-libGL-devel mesa-libEGL-devel mesa-libOSMesa-devel
dnf clean all

test -x "$USD_PREFIX/bin/usdrecord"
test -d "$USD_PREFIX/lib/python/pxr"
PYTHONPATH="$USD_PREFIX/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -c 'from pxr import Usd; print(Usd.GetVersion())' \
  | tee "$EVIDENCE_ROOT/openusd-version.txt"

find "$USD_PREFIX/lib" -maxdepth 1 -name 'libusd*.so*' -printf '%f\n' | sort \
  > "$EVIDENCE_ROOT/openusd-libraries.txt"
usd_lib_count="$(wc -l < "$EVIDENCE_ROOT/openusd-libraries.txt")"
if [[ "$usd_lib_count" -gt 1 ]]; then
  USD_LINKAGE=split
else
  USD_LINKAGE=monolithic
fi
printf 'OpenUSD libraries:\n'
cat "$EVIDENCE_ROOT/openusd-libraries.txt"
printf 'Detected OpenUSD linkage: %s\n' "$USD_LINKAGE" \
  | tee "$EVIDENCE_ROOT/openusd-linkage.txt"

! find "$USD_PREFIX/lib" -maxdepth 1 -name 'libtbb.so.2*' -print -quit | grep -q .
test -e /opt/cycles-dependencies/tbb/lib/libtbb.so.12

git clone --branch "$CYCLES_TAG" --depth 1 "$CYCLES_URL" "$BUILD_ROOT/cycles"
test "$(git -C "$BUILD_ROOT/cycles" rev-parse HEAD)" = "$CYCLES_REVISION"
test -z "$(git -C "$BUILD_ROOT/cycles" status --short)"

git -C "$BUILD_ROOT/cycles" diff > "$EVIDENCE_ROOT/cycles-applied.patch"
test ! -s "$EVIDENCE_ROOT/cycles-applied.patch"

(
  cd "$BUILD_ROOT/cycles"
  rm -rf lib/linux_x64
  mkdir -p lib
  cp -a /opt/cycles-dependencies lib/linux_x64
  make update

  test "$(git -C lib/linux_x64 rev-parse HEAD)" = "$CYCLES_LIB_REVISION"
  git status --short > "$EVIDENCE_ROOT/cycles-worktree-status.txt" || true
  test -z "$(git diff --name-only -- . ':!lib')"
  file lib/linux_x64/zstd/lib/libzstd.a |
    tee "$EVIDENCE_ROOT/cycles-zstd-file.txt"
  ar t lib/linux_x64/zstd/lib/libzstd.a \
    > "$EVIDENCE_ROOT/cycles-zstd-members.txt"
  test -s "$EVIDENCE_ROOT/cycles-zstd-members.txt"

  cmake -B ./build \
    -DPXR_ROOT="$USD_PREFIX" \
    -DCMAKE_PROJECT_INCLUDE=/usr/local/share/cycles/import_openusd_dependencies.cmake
  make -j"$(nproc)"

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
  printf 'OpenUSD prefix: %s\n' "$USD_PREFIX"
  printf 'OpenUSD linkage: %s\n' "$USD_LINKAGE"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
  printf 'Python: '
  python3 --version
} > "$EVIDENCE_ROOT/source-revisions.txt"

LD_LIBRARY_PATH="/opt/cycles/lib:/opt/cycles-dependencies/tbb/lib:$USD_PREFIX/lib:$USD_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  ldd -r /opt/cycles/hydra/hdCycles.so |
  tee "$EVIDENCE_ROOT/hdCycles-ldd.txt"
! grep -Eq 'not found|undefined symbol' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
grep -q 'libtbb.so.12' "$EVIDENCE_ROOT/hdCycles-ldd.txt"
! grep -q 'libtbb.so.2 ' "$EVIDENCE_ROOT/hdCycles-ldd.txt"

readelf -d /opt/cycles/hydra/hdCycles.so \
  > "$EVIDENCE_ROOT/hdCycles-dynamic.txt"
find /opt/cycles -type f -print | sort \
  > "$EVIDENCE_ROOT/cycles-install-manifest.txt"

rm -rf "$BUILD_ROOT"
