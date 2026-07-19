#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root="${1:?evidence directory required}"
mkdir -p "${root}"/{metadata,results}

dnf -y install mesa-dri-drivers mesa-libGL mesa-libEGL mesa-libGLU \
  xorg-x11-server-Xvfb glx-utils \
  >"${root}/metadata/mesa-dri-install.log" 2>&1
rpm -q mesa-dri-drivers mesa-libGL mesa-libEGL mesa-libGLU \
  xorg-x11-server-Xvfb glx-utils \
  >"${root}/metadata/mesa-packages.txt"

dnf -y install python3-pip >"${root}/metadata/rez-install.log" 2>&1
python3 -m pip install --no-cache-dir rez \
  >>"${root}/metadata/rez-install.log" 2>&1

python_bin="$(command -v python3)"
for tool in usdrecord usdchecker usdcat usdresolve; do
  if [[ -f "/usr/local/bin/${tool}" ]] &&
    head -n 1 "/usr/local/bin/${tool}" | grep -q "/opt/conan_home/.*python"; then
    sed -i "1s|^#!.*python.*\$|#!${python_bin}|" "/usr/local/bin/${tool}"
  fi
done

rez_root="${root}/rez-packages"
mkdir -p "${rez_root}/usd/24.08"
cat >"${rez_root}/usd/24.08/package.py" <<'PY'
name = "usd"
version = "24.08"

def commands():
    path = "/usr/local"
    env.PYTHONPATH.append(path + "/lib/python")
    env.PATH.append(path + "/bin")
PY

export REZ_PACKAGES_PATH="${rez_root}"
export PATH="/usr/local/bin:${PATH}"
export PYTHONPATH="/usr/local/lib/python:${PYTHONPATH:-}"
render_context="${DIAGNOSTIC_RENDER_CONTEXT:-egl-noqt}"
case "${render_context}" in
  egl-noqt) usdrecord_script="/src/scripts/tests/usdrecord_egl_noqt.py" ;;
  stock-xvfb) usdrecord_script="" ;;
  *) echo "DIAGNOSTIC_RENDER_CONTEXT must be egl-noqt or stock-xvfb" >&2; exit 2 ;;
esac
export DIAGNOSTIC_RENDER_CONTEXT="${render_context}"
export DIAGNOSTIC_REQUIRE_MATERIALX_PYTHON=0
export DIAGNOSTIC_OPENCHESSSET_REQUIRED="${DIAGNOSTIC_OPENCHESSSET_REQUIRED:-0}"
export DIAGNOSTIC_OPENCHESSSET_TIMEOUT="${DIAGNOSTIC_OPENCHESSSET_TIMEOUT:-300}"
export DIAGNOSTIC_LD_PRELOAD="${DIAGNOSTIC_LD_PRELOAD:-}"

command -v rez >/dev/null 2>&1 || {
  echo "CY2024 image has no Rez command" >&2
  exit 1
}
usdrecord_python="$(rez env usd -- bash -lc 'command -v python3')"
if [[ -z "${usdrecord_script}" ]]; then
  usdrecord_script="$(rez env usd -- bash -lc 'command -v usdrecord')"
fi
[[ -x "${usdrecord_python}" && -f "${usdrecord_script}" ]] || {
  echo "Rez USD environment did not provide python3/usdrecord script" >&2
  exit 1
}

stdlib_path="$(find /usr/local /opt -type d -path '*/share/MaterialX/libraries' \
  -print -quit 2>/dev/null || true)"
[[ -n "${stdlib_path}" ]] || {
  echo "CY2024 image has no MaterialX libraries directory" >&2
  exit 1
}
stdlib_parent="$(dirname "${stdlib_path}")"

{
  echo "image=${CY2024_IMAGE:-aswf/ci-vfxall:2024}"
  echo "image_digest=${CY2024_IMAGE_DIGEST:-unknown}"
  echo "openusd=24.08"
  echo "materialx=1.39.1"
  echo "renderer=GL"
  echo "render_context=${render_context}"
  uname -a
  nproc
  free -h
  "${usdrecord_python}" -c 'import sys; print(sys.executable, sys.version)'
  rez env usd -- python3 -c 'from pxr import Usd; print(Usd.GetVersion())'
  if ! rez env usd -- python3 -c 'import MaterialX as mx; print(mx.getVersionString())'; then
    echo "MaterialX Python bindings unavailable (optional for this render gate)"
  fi
  echo "materialx_libraries=${stdlib_path}"
  echo "materialx_parent=${stdlib_parent}"
  echo "DIAGNOSTIC_LD_PRELOAD=${DIAGNOSTIC_LD_PRELOAD:-unset}"
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

case "${DIAGNOSTIC_MTLX_STDLIB_PATH_MODE:-both}" in
  parent) modes=(parent) ;;
  libraries) modes=(libraries) ;;
  both) modes=(parent libraries) ;;
  *) echo "DIAGNOSTIC_MTLX_STDLIB_PATH_MODE must be parent, libraries, or both" >&2; exit 2 ;;
esac

result=0
for mode in "${modes[@]}"; do
  if [[ "${mode}" == parent ]]; then
    stdlib_path_for_mode="${stdlib_parent}"
  else
    stdlib_path_for_mode="${stdlib_path}"
  fi
  export PXR_MTLX_STDLIB_SEARCH_PATHS="${stdlib_path_for_mode}"
  printf '%s\n' "${stdlib_path_for_mode}" \
    >"${root}/metadata/materialx-stdlib-path-${mode}.txt"
  set +e
  rez env usd -- env \
    PXR_MTLX_STDLIB_SEARCH_PATHS="${stdlib_path_for_mode}" \
    DIAGNOSTIC_RENDER_CONTEXT="${render_context}" \
    DIAGNOSTIC_USDRECORD_PYTHON="${usdrecord_python}" \
    DIAGNOSTIC_USDRECORD_SCRIPT="${usdrecord_script}" \
    DIAGNOSTIC_LD_PRELOAD="${DIAGNOSTIC_LD_PRELOAD}" \
    /src/scripts/tests/openusd_materialx_render_smoke.sh \
    "${root}/results/smoke-${mode}"
  status=$?
  set -e
  echo "${status}" >"${root}/metadata/smoke-${mode}.exit"
  [[ "${status}" == 0 ]] || result=1
done

exit "${result}"
