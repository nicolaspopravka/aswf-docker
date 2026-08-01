#!/usr/bin/env bash

set -euxo pipefail

readonly OPENUSD_URL="https://github.com/PixarAnimationStudios/OpenUSD.git"
readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-dependency-evidence"

: "${OPENUSD_TAG:?OPENUSD_TAG is required}"
: "${OPENUSD_REVISION:?OPENUSD_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"
: "${TBB_ABI:?TBB_ABI is required}"

case "$TBB_ABI" in
  classic|onetbb) ;;
  *) echo "Unsupported TBB_ABI: $TBB_ABI" >&2; exit 1 ;;
esac

source /opt/rh/gcc-toolset-11/enable
mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

dnf install -y \
  binutils file git git-lfs glx-utils mesa-dri-drivers patch wget
dnf clean all
rpm -q mesa-dri-drivers mesa-libEGL mesa-libGL glx-utils \
  | tee "$EVIDENCE_ROOT/mesa-packages.txt"

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

file "$BUILD_ROOT/lib-linux_x64/zstd/lib/libzstd.a" \
  | tee "$EVIDENCE_ROOT/cycles-zstd-file.txt"
ar t "$BUILD_ROOT/lib-linux_x64/zstd/lib/libzstd.a" \
  > "$EVIDENCE_ROOT/cycles-zstd-members.txt"
test -s "$EVIDENCE_ROOT/cycles-zstd-members.txt"

cp -a "$BUILD_ROOT/lib-linux_x64" /opt/cycles-dependencies
mkdir -p /opt/usd
cp -a /opt/cycles-dependencies/tbb/. /opt/usd/

usd_build_args=(/opt/usd --no-usdview)
if [[ "$TBB_ABI" == classic ]]; then
  test -e /opt/usd/lib/libtbb.so.2
  test ! -e /opt/usd/lib/libtbb.so.12
  usd_build_args+=(--build-args "USD,-DTBB_ROOT_DIR=/opt/usd")
else
  test -e /opt/usd/lib/libtbb.so.12
  test -f /opt/usd/lib/cmake/TBB/TBBConfig.cmake
  usd_build_args+=(--onetbb)
  usd_build_args+=(--build-args "USD,-DTBB_DIR=/opt/usd/lib/cmake/TBB")
fi

git clone --branch "$OPENUSD_TAG" --depth 1 "$OPENUSD_URL" "$BUILD_ROOT/OpenUSD"
test "$(git -C "$BUILD_ROOT/OpenUSD" rev-parse HEAD)" = "$OPENUSD_REVISION"
(
  cd "$BUILD_ROOT/OpenUSD"
  python3 build_scripts/build_usd.py "${usd_build_args[@]}"
)

test -x /opt/usd/bin/usdrecord
test -d /opt/usd/lib/python/pxr
if [[ "$TBB_ABI" == classic ]]; then
  test -e /opt/usd/lib/libtbb.so.2
  test ! -e /opt/usd/lib/libtbb.so.12
else
  test -e /opt/usd/lib/libtbb.so.12
  ! find /opt/usd -maxdepth 2 -name 'libtbb.so.2*' -print -quit | grep -q .
fi

usd_cache="$(find /opt/usd -path '*/OpenUSD/CMakeCache.txt' -print -quit)"
test -n "$usd_cache"
cp "$usd_cache" "$EVIDENCE_ROOT/OpenUSD-CMakeCache.txt"

{
  printf 'OpenUSD tag: %s\n' "$OPENUSD_TAG"
  printf 'OpenUSD revision: %s\n' "$OPENUSD_REVISION"
  printf 'Cycles Linux libraries revision: %s\n' "$CYCLES_LIB_REVISION"
  printf 'TBB ABI: %s\n' "$TBB_ABI"
  gcc --version | head -1
  cmake --version | head -1
  python3 --version
} > "$EVIDENCE_ROOT/source-revisions.txt"

find /opt/usd -type f -print | sort > "$EVIDENCE_ROOT/openusd-install-manifest.txt"
find /opt/cycles-dependencies -type f -print | sort \
  > "$EVIDENCE_ROOT/cycles-dependencies-manifest.txt"
rm -rf /opt/usd/src "$BUILD_ROOT/OpenUSD"
