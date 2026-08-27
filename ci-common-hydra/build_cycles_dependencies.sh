#!/usr/bin/env bash
set -euxo pipefail

readonly CYCLES_LIB_URL="https://projects.blender.org/blender/lib-linux_x64.git"
readonly BUILD_ROOT="/opt/build"
readonly EVIDENCE_ROOT="/opt/cycles-dependency-evidence"

: "${CYCLES_LIB_REVISION:?CYCLES_LIB_REVISION is required}"

mkdir -p "$BUILD_ROOT" "$EVIDENCE_ROOT"

dnf install -y binutils file git git-lfs
dnf clean all

git lfs version
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
  printf 'Cycles Linux libraries revision: %s\n' "$CYCLES_LIB_REVISION"
  printf 'Git LFS: '
  git lfs version
} > "$EVIDENCE_ROOT/source-revisions.txt"

find /opt/cycles-dependencies -type f -print | sort \
  > "$EVIDENCE_ROOT/cycles-dependencies-manifest.txt"

rm -rf "$BUILD_ROOT"
