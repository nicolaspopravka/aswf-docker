#!/usr/bin/env bash
set -euo pipefail
output_root="${1:?}"
renderer="${2:?}"
year="${3:?}"
mkdir -p "${output_root}"
dnf -y install xorg-x11-server-Xvfb mesa-dri-drivers mesa-libGL libepoxy > "${output_root}/packages.log" 2>&1
if [[ "${year}" == 2024 ]]; then
    export LD_LIBRARY_PATH="/usr/lib64/llvm17/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
export PYTHONPATH=/usr/local/lib/python
export PXR_MTLX_STDLIB_SEARCH_PATHS=/usr/local/share/MaterialX/libraries
export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 QT_QPA_PLATFORM=xcb
unset LD_PRELOAD LP_NUM_THREADS GALLIVM_PERF
Xvfb :99 -screen 0 1280x960x24 +extension GLX +render -noreset > "${output_root}/xvfb.log" 2>&1 &
xvfb_pid=$!
trap 'kill "${xvfb_pid}" 2>/dev/null || true' EXIT
sleep 2
python3 /probe/issue10_material_fixture.py "${output_root}/chess-material.usda" > "${output_root}/fixture.log" 2>&1
for fixture in minimal chess-material; do
    scene="/probe/issue10_minimal.usda"
    [[ "${fixture}" != chess-material ]] || scene="${output_root}/chess-material.usda"
    camera_args=()
    [[ "${fixture}" != chess-material ]] || camera_args=(--camera /Camera)
    status=0
    date -u > "${output_root}/${fixture}-start.txt"
    timeout -k 15 5400 python3 -u "$(command -v usdrecord)" --renderer "${renderer}" --imageWidth 128 "${camera_args[@]}" \
        "${scene}" "${output_root}/${fixture}.png" > "${output_root}/${fixture}.log" 2>&1 || status=$?
    echo "${status}" > "${output_root}/${fixture}.status"
    date -u > "${output_root}/${fixture}-end.txt"
done
