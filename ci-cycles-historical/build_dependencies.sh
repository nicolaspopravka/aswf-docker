#!/usr/bin/env bash

set -euxo pipefail

readonly OPENUSD_URL="https://github.com/PixarAnimationStudios/OpenUSD.git"
readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-dependency-evidence"

: "${OPENUSD_TAG:?OPENUSD_TAG is required}"
: "${OPENUSD_REVISION:?OPENUSD_REVISION is required}"
: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"
: "${MATERIALX_VERSION:?MATERIALX_VERSION is required}"
CYCLES_MATERIALX_VERSION="${CYCLES_MATERIALX_VERSION:-$MATERIALX_VERSION}"
OPENUSD_MATERIALX_VERSION="${OPENUSD_MATERIALX_VERSION:-$MATERIALX_VERSION}"
: "${ENABLE_OPENVDB:=false}"
: "${TBB_ABI:?TBB_ABI is required}"

case "$ENABLE_OPENVDB" in
  true|false) ;;
  *) echo "Unsupported ENABLE_OPENVDB value: $ENABLE_OPENVDB" >&2; exit 1 ;;
esac

case "$TBB_ABI" in
  classic|onetbb) ;;
  *) echo "Unsupported TBB_ABI: $TBB_ABI" >&2; exit 1 ;;
esac

source "/opt/rh/gcc-toolset-${ASWF_DTS_VERSION}/enable"
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

IFS=. read -r materialx_major materialx_minor materialx_build \
  <<< "$CYCLES_MATERIALX_VERSION"
materialx_generated="$BUILD_ROOT/lib-linux_x64/materialx/include/MaterialXCore/Generated.h"
grep -Fq "#define MATERIALX_MAJOR_VERSION $materialx_major" "$materialx_generated"
grep -Fq "#define MATERIALX_MINOR_VERSION $materialx_minor" "$materialx_generated"
grep -Fq "#define MATERIALX_BUILD_VERSION $materialx_build" "$materialx_generated"

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

# OpenUSD 23.08 and 24.05 still point at retired dependency endpoints. Seed
# their normal source caches from Boost's official archive and verify the
# published checksums; build_usd.py then follows its unchanged build path.
if [[ "$OPENUSD_TAG" == v23.08 ]]; then
  readonly BOOST_ARCHIVE="/opt/usd/src/boost_1_78_0.zip"
  readonly BOOST_SHA256="f22143b5528e081123c3c5ed437e92f648fe69748e95fa6e2bd41484e2986cc3"
  mkdir -p /opt/usd/src
  wget --tries=4 --timeout=30 \
    --output-document "$BOOST_ARCHIVE" \
    https://archives.boost.io/release/1.78.0/source/boost_1_78_0.zip
  printf '%s  %s\n' "$BOOST_SHA256" "$BOOST_ARCHIVE" | sha256sum --check
  file "$BOOST_ARCHIVE" | tee "$EVIDENCE_ROOT/boost-archive-file.txt"
elif [[ "$OPENUSD_TAG" == v24.05 ]]; then
  readonly BOOST_ARCHIVE="/opt/usd/src/boost_1_82_0.zip"
  readonly BOOST_SHA256="f7c9e28d242abcd7a2c1b962039fcdd463ca149d1883c3a950bbcc0ce6f7c6d9"
  mkdir -p /opt/usd/src
  wget --tries=4 --timeout=30 \
    --output-document "$BOOST_ARCHIVE" \
    https://archives.boost.org/release/1.82.0/source/boost_1_82_0.zip
  printf '%s  %s\n' "$BOOST_SHA256" "$BOOST_ARCHIVE" | sha256sum --check
  file "$BOOST_ARCHIVE" | tee "$EVIDENCE_ROOT/boost-archive-file.txt"
fi

usd_build_args=(/opt/usd --no-usdview)
usd_dependency_build_args=()
if [[ "$ENABLE_OPENVDB" == true ]]; then
  usd_build_args+=(--openvdb)
  usd_dependency_build_args+=("Blosc,-DCMAKE_POLICY_VERSION_MINIMUM=3.5")
fi
if [[ "$TBB_ABI" == classic ]]; then
  test -e /opt/usd/lib/libtbb.so.2
  test ! -e /opt/usd/lib/libtbb.so.12
  usd_dependency_build_args+=("USD,-DTBB_ROOT_DIR=/opt/usd")
else
  test -e /opt/usd/lib/libtbb.so.12
  test -f /opt/usd/lib/cmake/TBB/TBBConfig.cmake
  usd_build_args+=(--onetbb)
  usd_dependency_build_args+=("USD,-DTBB_DIR=/opt/usd/lib/cmake/TBB")
fi
usd_build_args+=(--build-args "${usd_dependency_build_args[@]}")

git clone --branch "$OPENUSD_TAG" --depth 1 "$OPENUSD_URL" "$BUILD_ROOT/OpenUSD"
test "$(git -C "$BUILD_ROOT/OpenUSD" rev-parse HEAD)" = "$OPENUSD_REVISION"
grep -Fq "MaterialX/archive/v${OPENUSD_MATERIALX_VERSION}.zip" \
  "$BUILD_ROOT/OpenUSD/build_scripts/build_usd.py"
(
  cd "$BUILD_ROOT/OpenUSD"
  python3 build_scripts/build_usd.py "${usd_build_args[@]}"
)

test -x /opt/usd/bin/usdrecord
test -d /opt/usd/lib/python/pxr
if [[ "$ENABLE_OPENVDB" == true ]]; then
  test -f /opt/usd/lib/usd/hioOpenVDB/resources/plugInfo.json
  grep -Fq 'PXR_ENABLE_OPENVDB_SUPPORT:BOOL=ON' \
    "$BUILD_ROOT/OpenUSD/build/OpenUSD/CMakeCache.txt"
  PXR_PLUGINPATH_NAME=/opt/cycles/hydra python3 - <<'PY'
from pxr import Plug

names = {plugin.name for plugin in Plug.Registry().GetAllPlugins()}
assert "hioOpenVDB" in names, sorted(name for name in names if "VDB" in name)
PY
fi
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
  printf 'Cycles MaterialX version: %s\n' "$CYCLES_MATERIALX_VERSION"
  printf 'OpenUSD MaterialX version: %s\n' "$OPENUSD_MATERIALX_VERSION"
  printf 'OpenUSD OpenVDB support: %s\n' "$ENABLE_OPENVDB"
  printf 'TBB ABI: %s\n' "$TBB_ABI"
  gcc --version | head -1
  cmake --version | head -1
  python3 --version
} > "$EVIDENCE_ROOT/source-revisions.txt"

find /opt/usd -type f -print | sort > "$EVIDENCE_ROOT/openusd-install-manifest.txt"
find /opt/cycles-dependencies -type f -print | sort \
  > "$EVIDENCE_ROOT/cycles-dependencies-manifest.txt"
rm -rf /opt/usd/src "$BUILD_ROOT/OpenUSD"
