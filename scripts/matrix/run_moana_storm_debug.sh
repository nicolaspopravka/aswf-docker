#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

mode="${1:-}"
scene="${MOANA_SCENE:-/workspace/usd-render-benchmark/scenes/MoanaIsland/usd/island.usda}"
camera="${MOANA_CAMERA:-/island/cam/shotCam}"
python_bin="${MOANA_PYTHON:-/usr/local/bin/python3}"
egl_wrapper="${MOANA_EGL_WRAPPER:-/workspace/usdrecord_egl.py}"
output_root="${MOANA_DEBUG_OUT:-/workspace/moana-debug-$(date -u +%Y%m%dT%H%M%SZ)}"

self_test() {
  command -v gdb
  command -v readelf
  "${python_bin}" - <<'PY'
from pxr import Plug, Usd
import pxr
assert Usd.GetVersion() == (0, 26, 3)
assert pxr.__file__.startswith("/usr/local/")
plugins = {plugin.name for plugin in Plug.Registry().GetAllPlugins()}
assert "hdStorm" in plugins
print("OpenUSD 26.03 and hdStorm resolved from /usr/local")
PY
  grep -Fq '.debug_info' /opt/openusd-build-evidence/runtime/debug-sections.txt
  grep -Fq '.debug_line' /opt/openusd-build-evidence/runtime/debug-sections.txt
  grep -Fq 'Build ID:' /opt/openusd-build-evidence/runtime/build-ids.txt
  grep -Fq 'pxr/imaging/hdSt/material.cpp' \
    /opt/openusd-build-evidence/runtime/gdb-storm-symbols.txt
  [[ -s /opt/openusd-build-evidence/runtime/ptex-libraries.txt ]]
  [[ -s /opt/openusd-build-evidence/runtime/openvdb-libraries.txt ]]
  echo "Moana debug image self-test passed"
}

case "${mode}" in
  self-test)
    self_test
    exit 0
    ;;
  beach)
    subtree="/island/isBeach"
    ;;
  dunes)
    subtree="/island/isDunesB"
    ;;
  *)
    echo "usage: $0 {self-test|beach|dunes}" >&2
    exit 2
    ;;
esac

[[ -f "${scene}" ]] || {
  echo "Moana scene not found: ${scene}" >&2
  exit 2
}
[[ -f "${egl_wrapper}" ]] || {
  echo "EGL usdrecord wrapper not found: ${egl_wrapper}" >&2
  exit 2
}

mkdir -p "${output_root}"
case_name="${mode}"
population_mask="${subtree},${camera}"
image="${output_root}/${case_name}.png"
log="${output_root}/${case_name}.gdb.log"
command=(
  "${python_bin}" -u "${egl_wrapper}"
  --renderer Storm
  --camera "${camera}"
  --purposes render
  --mask "${population_mask}"
  -w 320
)
if [[ "${mode}" == beach && "${MOANA_MEMSTATS:-0}" == 1 ]]; then
  command+=(--memstats)
fi
command+=("${scene}" "${image}")

{
  printf 'mode=%s\n' "${mode}"
  printf 'scene=%s\n' "${scene}"
  printf 'camera=%s\n' "${camera}"
  printf 'population_mask=%s\n' "${population_mask}"
  printf 'python=%s\n' "${python_bin}"
  printf 'egl_wrapper=%s\n' "${egl_wrapper}"
  printf 'command='
  printf '%q ' "${command[@]}"
  printf '\n'
  nvidia-smi || true
  "${python_bin}" -c \
    'from pxr import Usd; print("OpenUSD", Usd.GetVersion())'
} > "${output_root}/${case_name}.metadata.txt" 2>&1

gdb_args=(
  --quiet
  --batch
  -ex 'set pagination off'
  -ex 'set confirm off'
  -ex 'set print thread-events off'
  -ex 'set debuginfod enabled off'
  -ex 'handle SIGSEGV stop print nopass'
)

if [[ "${mode}" == beach ]]; then
  gdb_args+=(
    -ex 'break PyErr_NoMemory'
    -ex 'commands'
    -ex 'silent'
    -ex 'echo \n=== PyErr_NoMemory ===\n'
    -ex 'thread apply all bt full'
    -ex 'continue'
    -ex 'end'
    -ex 'catch throw std::bad_alloc'
    -ex 'commands'
    -ex 'silent'
    -ex 'echo \n=== std::bad_alloc ===\n'
    -ex 'thread apply all bt full'
    -ex 'continue'
    -ex 'end'
  )
fi

gdb_args+=(
  -ex run
  -ex 'echo \n=== final inferior state ===\n'
  -ex 'thread apply all bt full'
  --args
  "${command[@]}"
)

set +e
gdb "${gdb_args[@]}" > "${log}" 2>&1
status=$?
set -e
if grep -Eiq 'llvmpipe|softpipe|swrast|software rasterizer' "${log}"; then
  echo "Rejected software OpenGL renderer; NVIDIA HW EGL is required." \
    | tee -a "${log}" >&2
  status=97
fi
printf '%s\n' "${status}" > "${output_root}/${case_name}.gdb-status.txt"
echo "GDB status ${status}; evidence: ${output_root}"
exit "${status}"
