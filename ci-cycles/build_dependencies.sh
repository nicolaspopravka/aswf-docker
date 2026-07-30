#!/usr/bin/env bash

set -euxo pipefail

readonly OPENUSD_URL="https://github.com/PixarAnimationStudios/OpenUSD.git"
readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-dependency-evidence"

: "${OPENUSD_TAG:?OPENUSD_TAG is required}"
: "${OPENUSD_REVISION:?OPENUSD_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"

source /opt/rh/gcc-toolset-14/enable

dnf install -y binutils file git git-lfs patch wget
dnf clean all

git lfs version
cmake --version
python3 --version
gcc --version

mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

git clone --branch "$OPENUSD_TAG" --depth 1 "$OPENUSD_URL" "$BUILD_ROOT/OpenUSD"
test "$(git -C "$BUILD_ROOT/OpenUSD" rev-parse HEAD)" = "$OPENUSD_REVISION"

(
  cd "$BUILD_ROOT/OpenUSD"
  python3 build_scripts/build_usd.py \
    --onetbb \
    --build-args "USD,-DTBB_DIR=/opt/usd/lib/cmake/TBB" \
    /opt/usd
)

test -x /opt/usd/bin/usdrecord
test -d /opt/usd/lib/python/pxr
test -e /opt/usd/lib/libtbb.so.12
if find /opt/usd/lib -maxdepth 1 -name 'libtbb.so.2*' -print -quit | grep -q .; then
  echo "Classic TBB unexpectedly present in the OpenUSD prefix" >&2
  exit 1
fi

usd_cache="$(find /opt/usd -path '*/OpenUSD/CMakeCache.txt' -print -quit)"
test -n "$usd_cache"
grep -E '^TBB_DIR(:[^=]*)?=/opt/usd/lib/cmake/TBB$' "$usd_cache"
cp "$usd_cache" "$EVIDENCE_ROOT/OpenUSD-CMakeCache.txt"

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

{
  printf 'OpenUSD tag: %s\n' "$OPENUSD_TAG"
  printf 'OpenUSD revision: %s\n' "$OPENUSD_REVISION"
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
