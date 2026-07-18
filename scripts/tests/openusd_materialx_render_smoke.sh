#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
root="${1:?evidence directory required}"
mkdir -p "${root}"/{images,logs,metadata}
render_context="${DIAGNOSTIC_RENDER_CONTEXT:-stock-xvfb}"
case "${render_context}" in
  stock-xvfb|egl-noqt) ;;
  *) echo "unknown render context: ${render_context}" >&2; exit 2 ;;
esac
usdrecord_python="${DIAGNOSTIC_USDRECORD_PYTHON:-/usr/local/bin/python3}"
if [[ "${render_context}" == egl-noqt ]]; then
  usdrecord_script="${DIAGNOSTIC_USDRECORD_SCRIPT:-/src/scripts/tests/usdrecord_egl_noqt.py}"
else
  usdrecord_script="${DIAGNOSTIC_USDRECORD_SCRIPT:-$(command -v usdrecord)}"
fi
[[ -x "${usdrecord_python}" ]] || {
  echo "stock usdrecord Python is not executable: ${usdrecord_python}" >&2
  exit 1
}
[[ -f "${usdrecord_script}" ]] || {
  echo "usdrecord script was not found: ${usdrecord_script}" >&2
  exit 1
}
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
unset MESA_LOADER_DRIVER_OVERRIDE
if [[ "${render_context}" == egl-noqt ]]; then
  unset DISPLAY
  export EGL_PLATFORM=surfaceless PXR_EGL_ALLOW_SOFTWARE_GL=1
  echo "not used by egl-noqt" >"${root}/metadata/xvfb.log"
else
  export DISPLAY=:99
  unset EGL_PLATFORM PXR_EGL_ALLOW_SOFTWARE_GL
  Xvfb :99 -screen 0 640x480x24 +extension GLX +render -noreset >"${root}/metadata/xvfb.log" 2>&1 &
  xvfb_pid=$!
  trap 'kill "${xvfb_pid}" 2>/dev/null || true' EXIT
  sleep 2
fi
{
  echo "DIAGNOSTIC_RENDER_CONTEXT=${render_context}"
  echo "LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
  echo "GALLIUM_DRIVER=${GALLIUM_DRIVER}"
  echo "MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE:-unset}"
  echo "DISPLAY=${DISPLAY:-unset}"
  echo "EGL_PLATFORM=${EGL_PLATFORM:-unset}"
  echo "PXR_EGL_ALLOW_SOFTWARE_GL=${PXR_EGL_ALLOW_SOFTWARE_GL:-unset}"
  echo "PXR_MTLX_STDLIB_SEARCH_PATHS=${PXR_MTLX_STDLIB_SEARCH_PATHS:-unset}"
  echo "NVIDIA_CPU_ONLY=${NVIDIA_CPU_ONLY:-unset}"
  echo "NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-unset}"
  echo "NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-unset}"
  echo "dri drivers:"
  find /usr/lib /usr/lib64 -type f \
    \( -name '*swrast*_dri.so' -o -name '*llvmpipe*' \) -print 2>/dev/null || true
  echo "GL/EGL libraries:"
  ldconfig -p 2>/dev/null | grep -E 'lib(GLX|GL|EGL|OSMesa)\.so' || true
} >"${root}/metadata/mesa-runtime.txt"
for utility in glxinfo eglinfo; do
  if command -v "${utility}" >/dev/null 2>&1; then
    utility_args=()
    [[ "${utility}" == glxinfo ]] && utility_args=(-B)
    set +e
    "${utility}" "${utility_args[@]}" >"${root}/metadata/${utility}.log" 2>&1
    utility_status=$?
    set -e
    echo "${utility_status}" >"${root}/metadata/${utility}.exit"
  else
    echo "not installed" >"${root}/metadata/${utility}.log"
    echo 127 >"${root}/metadata/${utility}.exit"
  fi
done
if [[ "${render_context}" == stock-xvfb ]]; then
  if [[ "$(<"${root}/metadata/glxinfo.exit")" != 0 ]] || \
    ! grep -Eqi 'OpenGL renderer string:.*llvmpipe|Device: llvmpipe' \
      "${root}/metadata/glxinfo.log"; then
    echo "software GL preflight did not select LLVMpipe" >&2
    exit 1
  fi
fi
qxcb_plugin="$(find /usr /opt -type f -name 'libqxcb.so' -print -quit 2>/dev/null || true)"
if [[ -n "${qxcb_plugin}" ]]; then
  {
    echo "${qxcb_plugin}"
    ldd "${qxcb_plugin}" || true
  } >"${root}/metadata/qxcb-linkage.txt" 2>&1
else
  echo "libqxcb.so not found" >"${root}/metadata/qxcb-linkage.txt"
fi
{
  "${usdrecord_python}" -c 'import sys; print(sys.executable, sys.version)'
  "${usdrecord_python}" -c 'import PySide6; print(PySide6.__file__)'
  echo "usdrecord=${usdrecord_script}"
  if [[ "${render_context}" == egl-noqt ]]; then
    sha256sum "${usdrecord_script}"
  fi
} >"${root}/metadata/usdrecord-python.txt"
"${usdrecord_python}" -c 'from pxr import Usd; print(Usd.GetVersion())' >"${root}/metadata/openusd.txt"
set +e
"${usdrecord_python}" -c 'import MaterialX as mx; print(mx.__file__, mx.getVersionString())' \
  >"${root}/metadata/materialx.txt" 2>&1
materialx_python_status=$?
set -e
echo "${materialx_python_status}" >"${root}/metadata/materialx.exit"
if [[ "${DIAGNOSTIC_REQUIRE_MATERIALX_PYTHON:-1}" == 1 && "${materialx_python_status}" != 0 ]]; then
  echo "MaterialX Python import failed" >&2
  exit 1
fi
result=0
for scene in usdpreview_control materialx_standard_surface; do
  set +e
  timeout 120 "${usdrecord_python}" "${usdrecord_script}" \
    --camera /World/Camera --renderer Storm --purposes render \
    --imageWidth 256 "/src/scripts/tests/fixtures/openusd-materialx/${scene}.usda" \
    "${root}/images/${scene}.png" >"${root}/logs/${scene}.log" 2>&1
  status=$?
  set -e
  echo "${status}" >"${root}/logs/${scene}.exit"
  [[ "${status}" == 0 && -s "${root}/images/${scene}.png" ]] || result=1
  grep -Eqi 'Failed to compile shader|Generated MaterialX Document does not have 1 material|Invalid port connection|Invalid info:id|undefined variable|undeclared' "${root}/logs/${scene}.log" && result=1 || true
  if [[ "${render_context}" == egl-noqt ]] && \
    ! grep -Eqi '^EGL [0-9]+\.[0-9]+$' "${root}/logs/${scene}.log"; then
    echo "${scene}: EGL initialization was not recorded" >&2
    result=1
  fi
  if [[ "${render_context}" == egl-noqt ]] && \
    ! grep -Eqi '^GL_RENDERER:.*llvmpipe' "${root}/logs/${scene}.log"; then
    echo "${scene}: EGL did not select LLVMpipe" >&2
    result=1
  fi
done
if [[ -n "${DIAGNOSTIC_OPENCHESSSET:-}" ]]; then
  [[ -f "${DIAGNOSTIC_OPENCHESSSET}" ]] || {
    echo "OpenChessSet input is missing: ${DIAGNOSTIC_OPENCHESSSET}" >&2
    result=1
  }
  if [[ -f "${DIAGNOSTIC_OPENCHESSSET}" ]]; then
    set +e
    timeout 300 "${usdrecord_python}" "${usdrecord_script}" \
      --camera main_cam --renderer Storm --purposes render \
      --imageWidth 512 "${DIAGNOSTIC_OPENCHESSSET}" \
      "${root}/images/openchessset.png" \
      >"${root}/logs/openchessset.log" 2>&1
    status=$?
    set -e
    echo "${status}" >"${root}/logs/openchessset.exit"
    [[ "${status}" == 0 && -s "${root}/images/openchessset.png" ]] || result=1
    grep -Eqi 'Failed to compile shader|Generated MaterialX Document does not have 1 material|Invalid port connection|Invalid info:id|undefined variable|undeclared' \
      "${root}/logs/openchessset.log" && result=1 || true
    if [[ "${render_context}" == egl-noqt ]] && \
      ! grep -Eqi '^EGL [0-9]+\.[0-9]+$' "${root}/logs/openchessset.log"; then
      echo "OpenChessSet: EGL initialization was not recorded" >&2
      result=1
    fi
    if [[ "${render_context}" == egl-noqt ]] && \
      ! grep -Eqi '^GL_RENDERER:.*llvmpipe' "${root}/logs/openchessset.log"; then
      echo "OpenChessSet: EGL did not select LLVMpipe" >&2
      result=1
    fi
  fi
fi
set +e
"${usdrecord_python}" -c '
import sys
from PySide6.QtGui import QImage
image = QImage(sys.argv[1])
colors = {image.pixel(x, y) for y in range(image.height()) for x in range(image.width())}
print(f"width={image.width()} height={image.height()} unique_rgba={len(colors)}")
raise SystemExit(0 if not image.isNull() and len(colors) > 1 else 1)
' "${root}/images/usdpreview_control.png" \
  > "${root}/metadata/usdpreview-image-variation.txt" 2>&1
preview_variation_status=$?
set -e
echo "${preview_variation_status}" \
  > "${root}/metadata/usdpreview-image-variation.exit"
[[ "${preview_variation_status}" == 0 ]] || result=1
if [[ -f "${root}/images/openchessset.png" ]]; then
  set +e
  "${usdrecord_python}" -c '
import sys
from PySide6.QtGui import QImage
image = QImage(sys.argv[1])
colors = {image.pixel(x, y) for y in range(image.height()) for x in range(image.width())}
print(f"width={image.width()} height={image.height()} unique_rgba={len(colors)}")
raise SystemExit(0 if not image.isNull() and len(colors) > 1 else 1)
' "${root}/images/openchessset.png" \
    > "${root}/metadata/openchessset-image-variation.txt" 2>&1
  openchessset_variation_status=$?
  set -e
  echo "${openchessset_variation_status}" \
    > "${root}/metadata/openchessset-image-variation.exit"
  [[ "${openchessset_variation_status}" == 0 ]] || result=1
fi
exit "${result}"
