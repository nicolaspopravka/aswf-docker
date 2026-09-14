#!/usr/bin/env bash

set -euo pipefail

output_root="${1:?output directory is required}"
renderer_token="${2:?renderer token is required}"
scene="/asset/chess_set.usda"
stdlib_path="/usr/local/share/MaterialX/libraries"

mkdir -p "${output_root}"

{
    date -u +%Y-%m-%dT%H:%M:%SZ
    uname -a
    cat /etc/os-release
    echo "renderer=${renderer_token}"
    echo "scene=${scene}"
    echo "asset_commit=907d5f17bbe933fc14441a3f3ab69a5bd8abe32a"
    echo "stdlib_path=${stdlib_path}"
} > "${output_root}/environment.txt"

{
    find /usr/local/lib/usd/usdMtlx/resources -maxdepth 2 -type f -print 2>&1 || true
    find "${stdlib_path}" -maxdepth 2 -type f -print 2>&1 || true
} > "${output_root}/materialx-files.txt"

dnf -y install xorg-x11-server-Xvfb mesa-dri-drivers mesa-libGL libepoxy \
    xorg-x11-utils > "${output_root}/packages.log" 2>&1

export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export QT_QPA_PLATFORM=xcb
export PYTHONPATH="/usr/local/lib/python${PYTHONPATH:+:${PYTHONPATH}}"
unset LD_PRELOAD

Xvfb "${DISPLAY}" -screen 0 1280x960x24 +extension GLX +render -noreset \
    > "${output_root}/xvfb.log" 2>&1 &
xvfb_pid=$!
trap 'kill "${xvfb_pid}" >/dev/null 2>&1 || true' EXIT
sleep 2

if ! kill -0 "${xvfb_pid}" 2>/dev/null; then
    echo "Xvfb failed to start" > "${output_root}/result.txt"
    exit 1
fi

failure_pattern='Invalid port connection|Unable to create the Glslfx Shader|mx_math\.glsl|AIRY_FRESNEL_ITERATIONS|undefined variable.*(L|edf1_out)|undefined symbol|Failed to compile shader'

result=PASS

for mode in default explicit-stdlib; do
    image="${output_root}/OpenChessSet-${mode}.png"
    log="${output_root}/OpenChessSet-${mode}.log"

    if [[ "${mode}" == default ]]; then
        unset PXR_MTLX_STDLIB_SEARCH_PATHS
    else
        export PXR_MTLX_STDLIB_SEARCH_PATHS="${stdlib_path}"
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

    echo "${render_status}" > "${output_root}/exit-status-${mode}.txt"

    {
        echo "mode=${mode}"
        echo "render_status=${render_status}"
        echo "PXR_MTLX_STDLIB_SEARCH_PATHS=${PXR_MTLX_STDLIB_SEARCH_PATHS-<unset>}"
        if [[ -s "${image}" ]]; then
            file "${image}"
            sha256sum "${image}"
            command -v oiiotool >/dev/null 2>&1 && oiiotool "${image}" --stats || true
        else
            echo "image_missing_or_empty"
        fi
    } > "${output_root}/image-metadata-${mode}.txt" 2>&1

    if [[ "${render_status}" -ne 0 || ! -s "${image}" ]]; then
        result=FAIL
    fi
    if grep -Eiq "${failure_pattern}" "${log}"; then
        result=FAIL
    fi
done

{
    echo "result=${result}"
    echo "renderer=${renderer_token}"
    sha256sum "${output_root}"/OpenChessSet-*.png 2>/dev/null || true
} > "${output_root}/result.txt"

if [[ "${result}" != PASS ]]; then
    exit 1
fi
