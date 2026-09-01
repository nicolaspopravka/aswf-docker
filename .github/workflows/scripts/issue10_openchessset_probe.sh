#!/usr/bin/env bash

set -euo pipefail

output_root="${1:?output directory is required}"
renderer_token="${2:?renderer token is required}"
scene="/asset/chess_set.usda"
image="${output_root}/OpenChessSet.png"
log="${output_root}/OpenChessSet.log"

mkdir -p "${output_root}"

{
    date -u +%Y-%m-%dT%H:%M:%SZ
    uname -a
    cat /etc/os-release
    echo "renderer=${renderer_token}"
    echo "scene=${scene}"
    echo "asset_commit=907d5f17bbe933fc14441a3f3ab69a5bd8abe32a"
} > "${output_root}/environment.txt"

dnf -y install xorg-x11-server-Xvfb mesa-dri-drivers mesa-libGL libepoxy \
    xorg-x11-utils > "${output_root}/packages.log" 2>&1

export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export QT_QPA_PLATFORM=xcb
export PYTHONPATH="/usr/local/lib/python${PYTHONPATH:+:${PYTHONPATH}}"
unset LD_PRELOAD PXR_MTLX_STDLIB_SEARCH_PATHS

Xvfb "${DISPLAY}" -screen 0 1280x960x24 +extension GLX +render -noreset \
    > "${output_root}/xvfb.log" 2>&1 &
xvfb_pid=$!
trap 'kill "${xvfb_pid}" >/dev/null 2>&1 || true' EXIT
sleep 2

if ! kill -0 "${xvfb_pid}" 2>/dev/null; then
    echo "Xvfb failed to start" > "${output_root}/result.txt"
    exit 1
fi

set +e
timeout 900 usdrecord \
    --camera main_cam \
    --renderer "${renderer_token}" \
    --purposes render \
    --imageWidth 512 \
    "${scene}" "${image}" > "${log}" 2>&1
render_status=$?
set -e

echo "${render_status}" > "${output_root}/exit-status.txt"

{
    echo "render_status=${render_status}"
    if [[ -s "${image}" ]]; then
        file "${image}"
        sha256sum "${image}"
        command -v oiiotool >/dev/null 2>&1 && oiiotool "${image}" --stats || true
    else
        echo "image_missing_or_empty"
    fi
} > "${output_root}/image-metadata.txt" 2>&1

failure_pattern='Invalid port connection|Unable to create the Glslfx Shader|mx_math\.glsl|AIRY_FRESNEL_ITERATIONS|undefined variable.*(L|edf1_out)|undefined symbol|Failed to compile shader'

result=PASS
if [[ "${render_status}" -ne 0 ]]; then
    result=FAIL
fi
if [[ ! -s "${image}" ]]; then
    result=FAIL
fi
if grep -Eiq "${failure_pattern}" "${log}"; then
    result=FAIL
fi

{
    echo "result=${result}"
    echo "render_status=${render_status}"
    echo "renderer=${renderer_token}"
    if [[ -s "${image}" ]]; then
        sha256sum "${image}"
    else
        echo "image=missing"
    fi
} > "${output_root}/result.txt"

if [[ "${result}" != PASS ]]; then
    exit 1
fi
