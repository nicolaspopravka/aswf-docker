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

set +e
LD_PRELOAD="${usdrecord_preload}" timeout 300 xvfb-run -a usdrecord \
    --renderer Moonray \
    --camera /World/Camera \
    --imageWidth 256 \
    "${validation_root}/minimal.usda" \
    "${evidence_root}/usdrecord-minimal.exr" \
    2>&1 | tee "${evidence_root}/usdrecord-minimal.log"
usdrecord_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "${usdrecord_status}" \
    > "${evidence_root}/usdrecord-minimal.exit"
test -s "${evidence_root}/usdrecord-minimal.exr"
python3 "${validation_root}/image_stats.py" \
    --require-variation \
    "${evidence_root}/usdrecord-minimal.exr" \
    | tee "${evidence_root}/usdrecord-minimal.stats.json"

sha256sum \
    "${evidence_root}/rectangle.exr" \
    "${evidence_root}/hd-render-sphere.exr" \
    "${evidence_root}/usdrecord-minimal.exr" \
    | tee "${evidence_root}/hard-gate-images.sha256"

# Validation-only issue #22 reduction. This intentionally stops the workflow
# before its image-publication steps after preserving the A/B evidence.
readonly hdmoonray_commit=986121dbb8817237c02a254d0c4470b5eb820f9e
readonly cmake_modules_commit=6e4c94b4d1376962f631284378ea859e66199e1b
readonly hdmoonray_source=/tmp/hdMoonray
readonly cmake_modules_source=/tmp/cmake_modules
readonly hdmoonray_build=/tmp/hdmoonray-build
readonly hdmoonray_overlay=/tmp/hdmoonray-overlay
readonly subdivision_scene="${moonray_root}/testSuite/geometry/subdivision/subdivision.usd"

dnf install -y cppunit-devel git
git clone https://github.com/OpenMoonRay/hdMoonray.git "${hdmoonray_source}"
git -C "${hdmoonray_source}" checkout --detach "${hdmoonray_commit}"
git -C "${hdmoonray_source}" apply --unidiff-zero \
    "${validation_root}/hdmoonray-refine-zero-smoothing.patch"
git -C "${hdmoonray_source}" diff --check
git -C "${hdmoonray_source}" diff \
    > "${evidence_root}/hdmoonray-refine-zero.patch"

git clone https://github.com/OpenMoonRay/cmake_modules.git \
    "${cmake_modules_source}"
git -C "${cmake_modules_source}" checkout --detach "${cmake_modules_commit}"

cmake -S "${hdmoonray_source}" -B "${hdmoonray_build}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MODULE_PATH="${cmake_modules_source}/cmake" \
    -DCMAKE_PREFIX_PATH="${moonray_root};/opt/MoonRay/dependencies/log4cplus;/usr/local" \
    -DBOOST_PYTHON_COMPONENT_NAME=python311 \
    -DLog4cplus_LIBRARIES=/opt/MoonRay/dependencies/log4cplus/lib/liblog4cplus.so \
    -DLog4cplus_INCLUDE_DIR=/opt/MoonRay/dependencies/log4cplus/include \
    -DMOONRAY_USE_OPTIX=OFF
cmake --build "${hdmoonray_build}" --target hydramoonray -- --jobs=2

mkdir -p "${hdmoonray_overlay}"
cp "${hdmoonray_build}/lib/hydramoonray/libhydramoonray.so" \
    "${hdmoonray_overlay}/"
test -s "${hdmoonray_overlay}/libhydramoonray.so"
sha256sum \
    "${moonray_root}/lib64/libhydramoonray.so" \
    "${hdmoonray_overlay}/libhydramoonray.so" \
    | tee "${evidence_root}/hydramoonray-libraries.sha256"

timeout 300 hd_render \
    -in "${subdivision_scene}" \
    -out "${evidence_root}/refine-zero-baseline.exr" \
    -refine-level 0 \
    -size 640 480 \
    2>&1 | tee "${evidence_root}/refine-zero-baseline.log"

LD_LIBRARY_PATH="${hdmoonray_overlay}:${LD_LIBRARY_PATH}" \
    ldd "${moonray_root}/plugin/hd_moonray_debug.so" \
    | tee "${evidence_root}/patched-plugin-ldd.txt"
grep -F "${hdmoonray_overlay}/libhydramoonray.so" \
    "${evidence_root}/patched-plugin-ldd.txt"

LD_LIBRARY_PATH="${hdmoonray_overlay}:${LD_LIBRARY_PATH}" \
    timeout 300 hd_render \
        -in "${subdivision_scene}" \
        -out "${evidence_root}/refine-zero-patched.exr" \
        -refine-level 0 \
        -size 640 480 \
        2>&1 | tee "${evidence_root}/refine-zero-patched.log"

python3 "${validation_root}/image_stats.py" --require-variation \
    "${evidence_root}/refine-zero-baseline.exr" \
    | tee "${evidence_root}/refine-zero-baseline.stats.json"
python3 "${validation_root}/image_stats.py" --require-variation \
    "${evidence_root}/refine-zero-patched.exr" \
    | tee "${evidence_root}/refine-zero-patched.stats.json"
sha256sum \
    "${evidence_root}/refine-zero-baseline.exr" \
    "${evidence_root}/refine-zero-patched.exr" \
    | tee "${evidence_root}/refine-zero-images.sha256"
if cmp -s \
    "${evidence_root}/refine-zero-baseline.exr" \
    "${evidence_root}/refine-zero-patched.exr"; then
    echo "patched render unexpectedly matches baseline" >&2
    exit 1
fi

set +e
oiiotool \
    "${evidence_root}/refine-zero-baseline.exr" \
    "${evidence_root}/refine-zero-patched.exr" \
    --diff 2>&1 | tee "${evidence_root}/refine-zero-image-diff.txt"
diff_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "${diff_status}" \
    > "${evidence_root}/refine-zero-image-diff.exit"
oiiotool "${evidence_root}/refine-zero-baseline.exr" \
    --colorconvert linear sRGB \
    -o "${evidence_root}/refine-zero-baseline.png"
oiiotool "${evidence_root}/refine-zero-patched.exr" \
    --colorconvert linear sRGB \
    -o "${evidence_root}/refine-zero-patched.png"

echo "Issue #22 validation complete; stopping before image publication." >&2
exit 1
