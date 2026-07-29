#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
harness="${repo_root}/scripts/matrix/build_openusd_path_image.sh"
debug_runner="${repo_root}/scripts/matrix/run_moana_storm_debug.sh"
workflow="${repo_root}/.github/workflows/targeted-openusd-materialx-images.yml"
dockerfile="${repo_root}/scripts/matrix/Dockerfile.openusd-build-path"

bash -n "${harness}"
bash -n "${debug_runner}"
bash -n "$0"

grep -Fq 'name: Build OpenUSD Moana debug image' "${workflow}"
grep -Fq 'workflow_dispatch:' "${workflow}"
grep -Fq 'packages: write' "${workflow}"
grep -Fq 'ghcr.io/${{ github.repository_owner }}/openusd-moana-debug' "${workflow}"
grep -Fq 'aswf/ci-common:6-clang19@sha256:4c0fd26c38fa9e848f500c3cd94edbd09183d82341b96b6285860ce57984b4c2' "${workflow}"
grep -Fq 'SOURCE_REVISION="1818e14bae0036ac4bc7b4e60826b5797076a4fe"' "${workflow}"
grep -Fq 'SOURCE_SHA256="590ea75ffa3ac0c35fdd080df04d61a696733b8f3d6a79bdc3f13f8077162d36"' "${workflow}"
grep -Fq 'SCRIPT_SHA256="268cdd366edfcbf6e8759553c94aff8f1e6b92e484cb809591aaeb47b668f8a9"' "${workflow}"
grep -Fq 'PYTHON_VERSION="3.13.14"' "${workflow}"
grep -Fq 'DEBUG_BUILD="1"' "${workflow}"
grep -Fq 'COPY run_moana_storm_debug.sh' "${dockerfile}"
grep -Fq 'COPY openusd-ptex-buffer-size-overflow.patch' "${dockerfile}"
grep -Fq 'COPY validate_ptex_file.cpp' "${dockerfile}"

grep -Fq -- '--build-variant' "${harness}"
grep -Fq 'relwithdebuginfo' "${harness}"
grep -Fq -- '--ptex' "${harness}"
grep -Fq -- '--openvdb' "${harness}"
grep -Fq -- '-fno-omit-frame-pointer' "${harness}"
grep -Fq 'Blosc,-DCMAKE_POLICY_VERSION_MINIMUM=3.5' "${harness}"
grep -Fq 'OpenVDB,-DTbb_tbb_LIBRARY_RELEASE=${INSTALL_PREFIX}/lib/libtbb.so -DTbb_tbb_LIBRARY_DEBUG=${INSTALL_PREFIX}/lib/libtbb.so' "${harness}"
grep -Fq '.debug_info' "${harness}"
grep -Fq '.debug_line' "${harness}"
grep -Fq 'Build ID:' "${harness}"
grep -Fq 'Rejected software OpenGL renderer' "${debug_runner}"
grep -Fq 'set breakpoint pending on' "${debug_runner}"
grep -Fq 'absent ASWF_OPENUSD_VERSION: Pixar base is not ci-usd' "${harness}"
grep -Fq 'patch -p1 --fuzz=0' "${harness}"
grep -Fq 'validate_ptex_file_asan' "${harness}"
grep -Fq 'PTEX_BUFFER_PATCH_SHA256="6865c0d3b26ad345bf6349b91f89cc2f0dabb79d120aef1219f175f16faeabf8"' "${workflow}"

env \
  BUILD_PATH=pixar-build-usd \
  CY=2026 \
  OPENUSD_VERSION=26.03 \
  MATERIALX_VERSION=1.39.3 \
  PYTHON_VERSION=3.13.14 \
  PYTHON_SHA256=5ae535a36af0ebca6fca176ecb8197f5db9c1cb8c8f0cd12cdf1787046db1f41 \
  SOURCE_REVISION=1818e14bae0036ac4bc7b4e60826b5797076a4fe \
  SOURCE_SHA256=590ea75ffa3ac0c35fdd080df04d61a696733b8f3d6a79bdc3f13f8077162d36 \
  SCRIPT_SHA256=268cdd366edfcbf6e8759553c94aff8f1e6b92e484cb809591aaeb47b668f8a9 \
  EXPECTED_GCC_MAJOR=14 \
  INSTALL_PREFIX=/usr/local \
  BUILD_JOBS=4 \
  ASWF_SOURCE_COMMIT=2c8484137a2f056a0abfd504dd5ad166240ab47e \
  WORKFLOW_REVISION=local-dry-run \
  DEBUG_BUILD=1 \
  PTEX_BUFFER_PATCH_SHA256=6865c0d3b26ad345bf6349b91f89cc2f0dabb79d120aef1219f175f16faeabf8 \
  "${harness}" dry-run \
  | grep -Fq 'build_variant=relwithdebuginfo'

echo "OpenUSD Moana debug image inputs are valid."
