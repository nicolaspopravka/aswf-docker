#!/usr/bin/env bash

set -euxo pipefail

readonly OPENUSD_URL="https://github.com/PixarAnimationStudios/OpenUSD.git"
readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-dependency-evidence"

: "${OPENUSD_TAG:?OPENUSD_TAG is required}"
: "${OPENUSD_REVISION:?OPENUSD_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"
: "${USD_LINKAGE:?USD_LINKAGE is required}"

case "$USD_LINKAGE" in
  split|monolithic) ;;
  *)
    echo "Unsupported USD_LINKAGE: $USD_LINKAGE" >&2
    exit 1
    ;;
esac

source /opt/rh/gcc-toolset-14/enable

dnf install -y binutils file git git-lfs patch wget
dnf clean all

git lfs version
cmake --version
python3 --version
gcc --version

mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

git lfs install --skip-repo
git clone "$CYCLES_LIB_URL" "$BUILD_ROOT/lib-linux_x64"
git -C "$BUILD_ROOT/lib-linux_x64" checkout --detach "$CYCLES_LIB_REVISION"
test "$(git -C "$BUILD_ROOT/lib-linux_x64" rev-parse HEAD)" = "$CYCLES_LIB_REVISION"
git -C "$BUILD_ROOT/lib-linux_x64" lfs pull
git -C "$BUILD_ROOT/lib-linux_x64" lfs fsck

git -C "$BUILD_ROOT/lib-linux_x64" lfs ls-files -n \
  > "$EVIDENCE_ROOT/cycles-lfs-files.txt"
test -s "$EVIDENCE_ROOT/cycles-lfs-files.txt"
while IFS= read -r lfs_path; do
  if head -c 42 "$BUILD_ROOT/lib-linux_x64/$lfs_path" |
    grep -q '^version https://git-lfs.github.com/spec/v1'; then
    echo "Unmaterialized Git LFS object: $lfs_path" >&2
    exit 1
  fi
done < "$EVIDENCE_ROOT/cycles-lfs-files.txt"

file "$BUILD_ROOT/lib-linux_x64/zstd/lib/libzstd.a" |
  tee "$EVIDENCE_ROOT/cycles-zstd-file.txt"
ar t "$BUILD_ROOT/lib-linux_x64/zstd/lib/libzstd.a" \
  > "$EVIDENCE_ROOT/cycles-zstd-members.txt"
test -s "$EVIDENCE_ROOT/cycles-zstd-members.txt"

cp -a "$BUILD_ROOT/lib-linux_x64" /opt/cycles-dependencies

# Use the exact oneTBB bundled with Cycles for OpenUSD and all build_usd.py
# dependencies. This keeps Embree, Cycles, and OpenUSD in one process ABI.
mkdir -p /opt/usd
cp -a /opt/cycles-dependencies/tbb/. /opt/usd/
test -e /opt/usd/lib/libtbb.so.12
test -f /opt/usd/lib/cmake/TBB/TBBConfig.cmake
nm -D /opt/usd/lib/libtbb.so.12 |
  c++filt |
  grep -F 'tbb::detail::r1::get_thread_reference_vertex' |
  tee "$EVIDENCE_ROOT/cycles-tbb-required-symbol.txt"

git clone --branch "$OPENUSD_TAG" --depth 1 "$OPENUSD_URL" "$BUILD_ROOT/OpenUSD"
test "$(git -C "$BUILD_ROOT/OpenUSD" rev-parse HEAD)" = "$OPENUSD_REVISION"

usd_build_args=(
  /opt/usd
  --onetbb
  --no-usdview
)
if [[ "$USD_LINKAGE" == monolithic ]]; then
  usd_build_args+=(--build-monolithic)
fi
usd_build_args+=(--build-args "USD,-DTBB_DIR=/opt/usd/lib/cmake/TBB")

(
  cd "$BUILD_ROOT/OpenUSD"
  python3 build_scripts/build_usd.py "${usd_build_args[@]}"
)

test -x /opt/usd/bin/usdrecord
test -d /opt/usd/lib/python/pxr
test -e /opt/usd/lib/libtbb.so.12
if find /opt/usd -maxdepth 2 -name 'libtbb.so.2*' -print -quit | grep -q .; then
  echo "Classic TBB unexpectedly present in the OpenUSD prefix" >&2
  exit 1
fi

usd_cache="$(find /opt/usd -path '*/OpenUSD/CMakeCache.txt' -print -quit)"
test -n "$usd_cache"
grep -E '^TBB_DIR(:[^=]*)?=/opt/usd/lib/cmake/TBB$' "$usd_cache"
if [[ "$USD_LINKAGE" == monolithic ]]; then
  grep -E '^PXR_BUILD_MONOLITHIC:BOOL=ON$' "$usd_cache"
else
  grep -E '^PXR_BUILD_MONOLITHIC:BOOL=OFF$' "$usd_cache"
fi
cp "$usd_cache" "$EVIDENCE_ROOT/OpenUSD-CMakeCache.txt"

{
  printf 'OpenUSD tag: %s\n' "$OPENUSD_TAG"
  printf 'OpenUSD revision: %s\n' "$OPENUSD_REVISION"
  printf 'OpenUSD linkage: %s\n' "$USD_LINKAGE"
  printf 'Cycles Linux libraries revision: %s\n' "$CYCLES_LIB_REVISION"
  printf 'Compiler: '
  gcc --version | head -1
  printf 'CMake: '
  cmake --version | head -1
  printf 'Python: '
  python3 --version
  printf 'Git LFS: '
  git lfs version
} > "$EVIDENCE_ROOT/source-revisions.txt"

find /opt/usd -type f -print | sort \
  > "$EVIDENCE_ROOT/openusd-install-manifest.txt"
find /opt/cycles-dependencies -type f -print | sort \
  > "$EVIDENCE_ROOT/cycles-dependencies-manifest.txt"

rm -rf /opt/usd/src "$BUILD_ROOT/OpenUSD"
