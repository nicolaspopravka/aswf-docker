#!/usr/bin/env bash
set -euo pipefail
output_root="${1:?}"
renderer="${2:?}"
mkdir -p "${output_root}"
bash /probe/issue10_discovery.sh "${output_root}/discovery"
dnf -y install xorg-x11-server-Xvfb mesa-dri-drivers mesa-libGL libepoxy procps-ng > "${output_root}/packages.log" 2>&1
export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 QT_QPA_PLATFORM=xcb
export PYTHONPATH=/usr/local/lib/python
unset LD_PRELOAD LP_NUM_THREADS GALLIVM_PERF
Xvfb :99 -screen 0 1280x960x24 +extension GLX +render -noreset > "${output_root}/xvfb.log" 2>&1 &
xvfb_pid=$!
trap 'kill "${xvfb_pid}" 2>/dev/null || true' EXIT
sleep 2
for mode in default explicit-stdlib; do
    if [[ "${mode}" == default ]]; then
        unset PXR_MTLX_STDLIB_SEARCH_PATHS
    else
        export PXR_MTLX_STDLIB_SEARCH_PATHS=/usr/local/share/MaterialX/libraries
    fi
    date -u > "${output_root}/${mode}-start.txt"
    timeout -k 15 5400 python3 -u "$(command -v usdrecord)" \
        --renderer "${renderer}" --imageWidth 512 --camera main_cam --purposes render \
        /asset/chess_set.usda "${output_root}/${mode}.png" > "${output_root}/${mode}.log" 2>&1 &
    render_pid=$!
    while kill -0 "${render_pid}" 2>/dev/null; do
        { date -u; ps -eo pid,ppid,etime,time,pcpu,rss,stat,comm; } >> "${output_root}/${mode}-progress.txt"
        sleep 30
    done
    status=0
    wait "${render_pid}" || status=$?
    echo "${status}" > "${output_root}/${mode}.status"
    date -u > "${output_root}/${mode}-end.txt"
done
