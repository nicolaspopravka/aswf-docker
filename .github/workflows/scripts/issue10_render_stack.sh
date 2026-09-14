#!/usr/bin/env bash
set -euo pipefail
output_root="${1:?}"
renderer="${2:?}"
mkdir -p "${output_root}"
dnf -y install gdb xorg-x11-server-Xvfb mesa-dri-drivers mesa-libGL libepoxy > "${output_root}/packages.log" 2>&1
export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 QT_QPA_PLATFORM=xcb
export PYTHONPATH=/usr/local/lib/python
export PXR_MTLX_STDLIB_SEARCH_PATHS=/usr/local/share/MaterialX/libraries
unset LD_PRELOAD
Xvfb :99 -screen 0 1280x960x24 +extension GLX +render -noreset > "${output_root}/xvfb.log" 2>&1 &
xvfb_pid=$!
trap 'kill "${xvfb_pid}" 2>/dev/null || true' EXIT
sleep 2
for scene in minimal chess; do
    args=(--renderer "${renderer}" --imageWidth 128)
    if [[ "${scene}" == minimal ]]; then
        args+=(/probe/issue10_minimal.usda)
    else
        args+=(--camera main_cam --purposes render /asset/chess_set.usda)
    fi
    python3 -u "$(command -v usdrecord)" "${args[@]}" "${output_root}/${scene}.png" > "${output_root}/${scene}.log" 2>&1 &
    render_pid=$!
    for attempt in $(seq 1 12); do
        kill -0 "${render_pid}" 2>/dev/null || break
        sleep 5
    done
    if kill -0 "${render_pid}" 2>/dev/null; then
        timeout -k 5 30 gdb -batch -p "${render_pid}" -ex 'set pagination off' -ex 'thread apply all bt 12' -ex detach > "${output_root}/${scene}-stack.txt" 2>&1 || true
        kill "${render_pid}" 2>/dev/null || true
        sleep 2
        kill -9 "${render_pid}" 2>/dev/null || true
        echo captured-and-stopped > "${output_root}/${scene}.result"
    fi
    status=0
    wait "${render_pid}" || status=$?
    echo "${status}" > "${output_root}/${scene}.status"
done
