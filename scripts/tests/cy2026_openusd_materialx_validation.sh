#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root="${1:?evidence directory required}"
mkdir -p "${root}"/{metadata,results}

install_software_gl() {
  dnf -y install mesa-dri-drivers xorg-x11-server-Xvfb glx-utils \
    >"${root}/metadata/mesa-dri-install.log" 2>&1
  rpm -q mesa-dri-drivers xorg-x11-server-Xvfb glx-utils \
    >"${root}/metadata/mesa-packages.txt"
}

install_software_gl

usdrecord_python="${DIAGNOSTIC_USDRECORD_PYTHON:-/usr/local/bin/python3}"
usdrecord_script="${DIAGNOSTIC_USDRECORD_SCRIPT:-$(command -v usdrecord)}"
[[ -x "${usdrecord_python}" ]] || {
  echo "stock usdrecord Python is not executable: ${usdrecord_python}" >&2
  exit 1
}
[[ -f "${usdrecord_script}" ]] || {
  echo "usdrecord script was not found: ${usdrecord_script}" >&2
  exit 1
}

stdlib_path="$(find /usr/local -type d -path '*/share/MaterialX/libraries' \
  -print -quit 2>/dev/null || true)"
[[ -n "${stdlib_path}" ]] || {
  echo "CY2026 image has no MaterialX libraries directory" >&2
  exit 1
}
export PXR_MTLX_STDLIB_SEARCH_PATHS="${stdlib_path}"
export DIAGNOSTIC_RENDER_CONTEXT=stock-xvfb
export DIAGNOSTIC_USDRECORD_PYTHON="${usdrecord_python}"
export DIAGNOSTIC_USDRECORD_SCRIPT="${usdrecord_script}"
export DIAGNOSTIC_REQUIRE_MATERIALX_PYTHON=0
export DIAGNOSTIC_OPENCHESSSET_REQUIRED="${DIAGNOSTIC_OPENCHESSSET_REQUIRED:-0}"
export DIAGNOSTIC_OPENCHESSSET_TIMEOUT="${DIAGNOSTIC_OPENCHESSSET_TIMEOUT:-300}"

{
  echo "image=${CY2026_IMAGE:-aswf/ci-vfxall:2026}"
  echo "image_digest=${CY2026_IMAGE_DIGEST:-unknown}"
  uname -a
  nproc
  free -h
  "${usdrecord_python}" -c 'import sys; print(sys.executable, sys.version)'
  "${usdrecord_python}" -c 'from pxr import Usd; print(Usd.GetVersion())'
  "${usdrecord_python}" -c 'import MaterialX as mx; print(mx.getVersionString())'
  echo "PXR_MTLX_STDLIB_SEARCH_PATHS=${PXR_MTLX_STDLIB_SEARCH_PATHS}"
} >"${root}/metadata/runtime.txt" 2>&1

if [[ "${DIAGNOSTIC_INCLUDE_OPENCHESSSET:-0}" == 1 ]]; then
  asset_root="${root}/input-assets"
  git init "${asset_root}"
  git -C "${asset_root}" remote add origin https://github.com/usd-wg/assets.git
  git -C "${asset_root}" -c protocol.version=2 fetch --depth=1 \
    --filter=blob:none origin 907d5f17bbe933fc14441a3f3ab69a5bd8abe32a
  git -C "${asset_root}" sparse-checkout init --cone
  git -C "${asset_root}" sparse-checkout set full_assets/OpenChessSet
  git -C "${asset_root}" checkout --detach FETCH_HEAD
  git -C "${asset_root}" rev-parse HEAD >"${root}/metadata/openchessset-commit.txt"
  export DIAGNOSTIC_OPENCHESSSET="${asset_root}/full_assets/OpenChessSet/chess_set.usda"
fi

set +e
/src/scripts/tests/openusd_materialx_render_smoke.sh "${root}/results/smoke"
status=$?
set -e
echo "${status}" >"${root}/metadata/smoke.exit"
exit "${status}"
