#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly moonray_root=/opt/MoonRay/installs/openmoonray
readonly evidence_root=/evidence
readonly validation_root=/validation

mkdir -p "${evidence_root}"
cp "${moonray_root}/testdata/rectangle.rdla" \
    "${moonray_root}/testdata/sphere.usd" \
    "${validation_root}/minimal.usda" \
    "${evidence_root}/"
sha256sum \
    "${evidence_root}/rectangle.rdla" \
    "${evidence_root}/sphere.usd" \
    "${evidence_root}/minimal.usda" \
    | tee "${evidence_root}/test-scenes.sha256"

test -L /opt/openmoonray
test "$(readlink -f /opt/openmoonray)" = "${moonray_root}"
test -s "${moonray_root}/sessions/hd_single.sessiondef"
grep -Fx 'tag=v2026.29.1' "${moonray_root}/share/openmoonray/provenance.txt"
grep -Fx 'commit=d96c6e30a8c280d4b5eb3bafa5e54efc445d7ea8' \
    "${moonray_root}/share/openmoonray/provenance.txt"
grep -Fx 'build_materialx_shaders=ON' \
    "${moonray_root}/share/openmoonray/provenance.txt"
grep -Fx 'lua_tool_version=5.4.4' \
    "${moonray_root}/share/openmoonray/provenance.txt"
grep -Fx 'log4cplus_version=2.1.2' \
    "${moonray_root}/share/openmoonray/provenance.txt"
grep -Fx 'log4cplus_unicode=OFF' \
    "${moonray_root}/share/openmoonray/provenance.txt"
grep -Fx 'external_scene_rdl2_pythonpath=OFF' \
    "${moonray_root}/share/openmoonray/provenance.txt"
test -s "${moonray_root}/share/openmoonray/openmoonray-issue-35.patch"
find "${moonray_root}/python/lib/python3.11" -type f -name shaders.py -print \
    | tee "${evidence_root}/generated-shaders-python.txt"
test -s "${evidence_root}/generated-shaders-python.txt"
test -f /opt/MoonRay/dependencies/log4cplus/lib/liblog4cplus.so
test -s /usr/local/share/openusd-cmake-relocation.txt
cmp \
    /usr/local/share/openusd-cmake-relocation.txt \
    "${moonray_root}/share/openmoonray/openusd-cmake-relocation.txt"
if grep -R -F '/opt/conan_home/' \
    /usr/local/pxrConfig.cmake \
    /usr/local/cmake/pxrTargets*.cmake; then
    echo "stale Conan-cache reference remains in OpenUSD exports" >&2
    exit 1
fi

find "${moonray_root}/shader_json" -type f -name '*.json' -print \
    | sort \
    | tee "${evidence_root}/shader-json-files.txt"
test -s "${evidence_root}/shader-json-files.txt"

readonly plugins=(
    "${moonray_root}/plugin/hd_moonray.so"
    "${moonray_root}/plugin/hd_moonray_debug.so"
    "${moonray_root}/plugin/moonrayShaderDiscovery.so"
    "${moonray_root}/plugin/moonrayShaderParser.so"
)
for plugin in "${plugins[@]}"; do
    test -f "${plugin}"
    ldd "${plugin}" | tee -a "${evidence_root}/plugin-ldd.txt"
done
if grep -F 'not found' "${evidence_root}/plugin-ldd.txt"; then
    echo "at least one required plugin has an unresolved dependency" >&2
    exit 1
fi

readonly logging_library="$(
    find "${moonray_root}" -type f -name 'librender_logging.so' -print -quit
)"
test -n "${logging_library}"
ldd "${logging_library}" | tee "${evidence_root}/log4cplus-ldd.txt"
grep -F \
    '/opt/MoonRay/dependencies/log4cplus/lib/liblog4cplus.so' \
    "${evidence_root}/log4cplus-ldd.txt"

python3 - <<'PY' | tee "${evidence_root}/renderer-discovery.txt"
from pxr import UsdImagingGL

plugins = UsdImagingGL.Engine.GetRendererPlugins()
entries = [
    (str(plugin), UsdImagingGL.Engine.GetRendererDisplayName(plugin))
    for plugin in plugins
]
for plugin, display_name in entries:
    print(f"{plugin}\t{display_name}")
if not any(display_name.lower() == "moonray" for _, display_name in entries):
    raise SystemExit("Moonray renderer was not discovered")
PY

export LIBGL_ALWAYS_SOFTWARE=1
export MESA_GL_VERSION_OVERRIDE=4.5
readonly usdrecord_preload=/usr/local/lib/libOpenImageIO_Util.so:/usr/local/lib/liboslquery.so
test -f /usr/local/lib/libOpenImageIO_Util.so
test -f /usr/local/lib/liboslquery.so

timeout 300 moonray \
    -in "${moonray_root}/testdata/rectangle.rdla" \
    -out "${evidence_root}/rectangle.exr" \
    2>&1 | tee "${evidence_root}/rectangle.log"
python3 "${validation_root}/image_stats.py" \
    --require-variation \
    "${evidence_root}/rectangle.exr" \
    | tee "${evidence_root}/rectangle.stats.json"

timeout 300 hd_render \
    -in "${moonray_root}/testdata/sphere.usd" \
    -out "${evidence_root}/hd-render-sphere.exr" \
    2>&1 | tee "${evidence_root}/hd-render-sphere.log"
python3 "${validation_root}/image_stats.py" \
    --require-variation \
    "${evidence_root}/hd-render-sphere.exr" \
    | tee "${evidence_root}/hd-render-sphere.stats.json"

LD_PRELOAD="${usdrecord_preload}" timeout 300 xvfb-run -a usdrecord \
    --renderer Moonray \
    --camera /World/Camera \
    --imageWidth 256 \
    "${validation_root}/minimal.usda" \
    "${evidence_root}/usdrecord-minimal.exr" \
    2>&1 | tee "${evidence_root}/usdrecord-minimal.log"
python3 "${validation_root}/image_stats.py" \
    --require-variation \
    "${evidence_root}/usdrecord-minimal.exr" \
    | tee "${evidence_root}/usdrecord-minimal.stats.json"

sha256sum \
    "${evidence_root}/rectangle.exr" \
    "${evidence_root}/hd-render-sphere.exr" \
    "${evidence_root}/usdrecord-minimal.exr" \
    | tee "${evidence_root}/hard-gate-images.sha256"
