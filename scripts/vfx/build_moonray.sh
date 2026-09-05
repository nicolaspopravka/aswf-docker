#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build OpenMoonRay against the ASWF-provided VFX dependencies (the ci-moonray
# image) and install it under the configured prefix (default:
# ASWF_INSTALL_PREFIX=/usr/local).
#
# Follows the official OpenMoonRay build instructions
# (building/general_build.md): clone the openmoonray superproject with its
# submodules, configure with CMake (dependencies are expected in /usr/local,
# the ASWF default), build, then:
#
#     cmake --install <build-dir> --prefix <install dir>
#
# The build directory is throwaway ("we don't care where the build is made");
# only the install lands in the image. CMake's install prefix is intentionally
# not set at configure time (OpenMoonRay remaps CMAKE_INSTALL_PREFIX=/usr/local
# to <source>/release), so the documented --prefix override is used instead.
#
# Known deviations from the pristine upstream flow (kept minimal and local so
# this script stays usable as the ASWF ci-moonray build step, and reported as
# findings until fixed upstream):
#   - The ASWF-deployed OpenUSD cmake exports (/usr/local/pxrConfig.cmake) carry
#     stale Conan-cache path hints, and OpenSubdiv is not exported as imported
#     targets. A shim rewrites the stale hints and synthesizes
#     OpenSubdiv::osdcpu/osdgpu against the deployed libs+headers.
#   - git-lfs is not shipped by the base image; it is installed so the
#     openmoonray submodules' LFS files can be pulled.
#   - ispc is present but may be unusable (missing libclang-cpp runtime); the
#     build proceeds and the failure point (if any) is reported in the log.
#   - CMake 4 (the ASWF pin) refuses OpenMoonRay's vendored
#     cmake_modules/cmake/FindTBB.cmake (its cmake_minimum_required predates
#     CMake 3.5). Configure uses the escape hatch CMake itself recommends,
#     -DCMAKE_POLICY_VERSION_MINIMUM=3.5; flagged to OpenMoonRay upstream.
#   - CMake 4's legacy FindBoost module delegates per-component config finds
#     (boost_systemConfig.cmake) that miss the ASWF-Boost versioned dirs
#     (boost_system-1.91.0/). With CMP0167 forced NEW, find_package(Boost)
#     uses the deployed umbrella BoostConfig.cmake, which handles components
#     itself; flagged upstream (CMP0167 is a CMake 4 project fixture).
#   - Boost 1.91's "system" component is header-only, so the ASWF deploy ships
#     no boost_system-* package and its umbrella config cannot find it. A
#     convention-matching header-only component shim is emitted for the
#     components MoonRay requests that the deploy omits; flagged upstream.
#
# Environment overrides (all optional):
#   MOONRAY_TAG, MOONRAY_COMMIT, MOONRAY_REPO_URL
#   MOONRAY_BUILD_ROOT, MOONRAY_SOURCE_DIR, MOONRAY_BUILD_DIR
#   CMAKE_INSTALL_PREFIX (default ${ASWF_INSTALL_PREFIX:-/usr/local})
#   BOOST_PYTHON_COMPONENT_NAME (default derived from ASWF_PYTHON_MAJOR_MINOR_VERSION)
#   BUILD_JOBS, BUILD_MATERIALX_SHADERS (default OFF), OPTIX_ROOT

set -ex

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
MOONRAY_TAG="${MOONRAY_TAG:-v2026.29.1}"
MOONRAY_COMMIT="${MOONRAY_COMMIT:-d96c6e30a8c280d4b5eb3bafa5e54efc445d7ea8}"
MOONRAY_REPO_URL="${MOONRAY_REPO_URL:-https://github.com/OpenMoonRay/openmoonray.git}"

# Throwaway build location; only the install is kept.
MOONRAY_BUILD_ROOT="${MOONRAY_BUILD_ROOT:-/tmp/openmoonray-build}"
MOONRAY_SOURCE_DIR="${MOONRAY_SOURCE_DIR:-${MOONRAY_BUILD_ROOT}/src}"
MOONRAY_BUILD_DIR="${MOONRAY_BUILD_DIR:-${MOONRAY_BUILD_ROOT}/cmake}"
rm -rf "${MOONRAY_BUILD_ROOT}"
mkdir -p "${MOONRAY_BUILD_ROOT}"

export CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${ASWF_INSTALL_PREFIX:-/usr/local}}"

PYTHON_MAJOR_MINOR="${ASWF_PYTHON_MAJOR_MINOR_VERSION:-3.13}"
BOOST_PYTHON_COMPONENT_NAME="${BOOST_PYTHON_COMPONENT_NAME:-python${PYTHON_MAJOR_MINOR//./}}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc || echo 4)}"

# MoonRay v2026.29.1 uses OptixDenoiserParams::denoiseAlpha, which was removed
# in OptiX 8; the ASWF image ships all OptiX SDK versions and upstream
# documents 7.6 for this MoonRay. Kept as an override so a newer MoonRay that
# supports OptiX 8 can opt in via OPTIX_ROOT.
export OPTIX_ROOT="${OPTIX_ROOT:-/usr/local/NVIDIA-OptiX-SDK-7.6.0}"

# ---------------------------------------------------------------------------
# Build-tool preflight
# ---------------------------------------------------------------------------
if ! command -v git-lfs >/dev/null 2>&1; then
    dnf -y install --quiet git-lfs
fi

test -x /usr/local/bin/cmake
test -x /usr/local/bin/ninja
test -x "/usr/local/bin/python${PYTHON_MAJOR_MINOR}"
test -f "/usr/local/lib/libpython${PYTHON_MAJOR_MINOR}.so"
test -f "/usr/local/include/python${PYTHON_MAJOR_MINOR}/Python.h"
test -x /usr/local/cuda/bin/nvcc
test -f "${OPTIX_ROOT}/include/optix.h"

# ispc is a listed MoonRay dependency on the ASWF conan stack; on some images
# it is not runnable (missing libclang-cpp runtime). Report rather than fail.
if ispc --version >/dev/null 2>&1; then
    echo "ispc OK: $(ispc --version 2>&1 | head -1)"
else
    echo "WARN: ispc present but unusable: $(ispc --version 2>&1 | head -1 || true)"
fi

# ---------------------------------------------------------------------------
# OpenUSD cmake relocation shim (ASWF deploy defect; see header)
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import re
from pathlib import Path

pxr_config = Path("/usr/local/pxrConfig.cmake")
targets = sorted(Path("/usr/local/cmake").glob("pxrTargets*.cmake"))
if not (pxr_config.is_file() and targets):
    raise SystemExit("OpenUSD cmake exports not found at /usr/local")
files = [pxr_config, *targets]

marker = "# ASWF deployed-image dependency relocation for OpenMoonRay"
hint = re.compile(
    r"if \(NOT \[\[/opt/conan_home/d/b/[^\]]+/b/build/Release/generators\]\] STREQUAL \"\"\)\n"
    r"(?P<indent>\s+)set\((?P<package>MaterialX|Imath)_DIR "
    r"\[\[/opt/conan_home/d/b/[^\]]+/b/build/Release/generators\]\]\)"
)

def repl(match):
    package = match.group("package")
    return (
        f'if (NOT [[/usr/local/lib/cmake/{package}]] STREQUAL "")\n'
        f'{match.group("indent")}set({package}_DIR '
        f'[[/usr/local/lib/cmake/{package}]]\u0029'
    )

for path in files:
    text = path.read_text()
    text, _ = hint.subn(repl, text)
    path.write_text(text)

text = pxr_config.read_text()
includes = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'
if marker not in text:
    block = f"""{marker}
if(NOT TARGET OpenSubdiv::osdcpu)
    add_library(OpenSubdiv::osdcpu SHARED IMPORTED)
    set_target_properties(OpenSubdiv::osdcpu PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libosdCPU.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()
if(NOT TARGET OpenSubdiv::osdgpu)
    add_library(OpenSubdiv::osdgpu SHARED IMPORTED)
    set_target_properties(OpenSubdiv::osdgpu PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libosdGPU.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()

{includes}"""
    if includes not in text:
        raise SystemExit("cannot locate pxrTargets include in pxrConfig.cmake")
    pxr_config.write_text(text.replace(includes, block, 1))

final = "\n".join(p.read_text() for p in files)
remaining = sorted(set(re.findall(r"/opt/conan_home/[^\"; )\n]+", final)))
if remaining:
    raise SystemExit(f"stale Conan-cache references remain in OpenUSD exports: {remaining}")
print("OpenUSD cmake: corrected stale Conan path hints and synthesized OpenSubdiv targets")

# Boost header-only component shims (same deploy-gap class). Boost 1.91's
# "system" component is header-only, so the ASWF deploy ships no
# boost_system-1.91.0 package, but arras4_core requests COMPONENTS system.
# Emit a convention-matching component package (mirrors the deployed
# boost_python-1.91.0/boost_python-config*.cmake files).
BOOST_CMAKE = Path("/usr/local/lib/cmake")
BOOST_CPP = "1.91.0"
BOOST_VERSION = "1.91.0"
HEADER_ONLY_BOOST_COMPONENTS = ("system",)
for comp in HEADER_ONLY_BOOST_COMPONENTS:
    dir_name = f"boost_{comp}-{BOOST_CPP}"
    pkg_dir = BOOST_CMAKE / dir_name
    (pkg_dir).mkdir(parents=True, exist_ok=True)
    config = pkg_dir / f"boost_{comp}-config.cmake"
    version = pkg_dir / f"boost_{comp}-config-version.cmake"
    if not config.exists():
        config.write_text(f"""# ASWF deployed-image dependency shim for OpenMoonRay ({comp} is header-only in Boost {BOOST_VERSION})
if(TARGET Boost::{comp})
  return()
endif()
get_filename_component(_BOOST_CMAKEDIR "${{CMAKE_CURRENT_LIST_DIR}}/../" REALPATH)
get_filename_component(_BOOST_INCLUDEDIR "${{_BOOST_CMAKEDIR}}/../../include/" ABSOLUTE)
if(NOT TARGET Boost::headers)
  add_library(Boost::headers INTERFACE IMPORTED)
  set_target_properties(Boost::headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${{_BOOST_INCLUDEDIR}}")
endif()
add_library(Boost::{comp} INTERFACE IMPORTED)
set_target_properties(Boost::{comp} PROPERTIES INTERFACE_LINK_LIBRARIES Boost::headers)
set(boost_{comp}_FOUND TRUE)
set(boost_{comp}_VERSION {BOOST_VERSION})
""")
    if not version.exists():
        version.write_text(f"""# Generated by Boost {BOOST_VERSION}
set(PACKAGE_VERSION {BOOST_VERSION})
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
""")
    print(f"Boost header-only component shim emitted: {dir_name}")
PYEOF

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
git clone \
    --branch "${MOONRAY_TAG}" \
    --depth 1 \
    --recurse-submodules \
    --shallow-submodules \
    "${MOONRAY_REPO_URL}" "${MOONRAY_SOURCE_DIR}" && \
test "$(git -C "${MOONRAY_SOURCE_DIR}" rev-parse HEAD)" = "${MOONRAY_COMMIT}" && \
git -C "${MOONRAY_SOURCE_DIR}" lfs pull && \
git -C "${MOONRAY_SOURCE_DIR}" submodule status --recursive

# ---------------------------------------------------------------------------
# Configure, build, install (the documented "cmake --install --prefix" flow)
# ---------------------------------------------------------------------------
export PATH="/usr/local/cuda/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

cmake \
    -S "${MOONRAY_SOURCE_DIR}" \
    -B "${MOONRAY_BUILD_DIR}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/usr/local \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_POLICY_DEFAULT_CMP0167=NEW \
    -DCUDAToolkit_ROOT=/usr/local/cuda \
    -DLUA_BIN_LUA:FILEPATH=/usr/local/bin/lua \
    -DLUA_BIN_LUAC:FILEPATH=/usr/local/bin/luac \
    -DPYTHON_EXECUTABLE=/usr/local/bin/python3.13 \
    -DPython3_EXECUTABLE=/usr/local/bin/python3.13 \
    -DPython3_LIBRARY=/usr/local/lib/libpython3.13.so \
    -DPython3_INCLUDE_DIR=/usr/local/include/python3.13 \
    -DBOOST_PYTHON_COMPONENT_NAME="${BOOST_PYTHON_COMPONENT_NAME}" \
    -DABI_VERSION=0 \
    -DBUILD_QT_APPS=NO \
    -DMOONRAY_USE_OPTIX=ON \
    -DBUILD_MATERIALX_SHADERS="${BUILD_MATERIALX_SHADERS:-OFF}"

# Hard assertions that the configure picked up the intended stack (a silently
# wrong dependency fails the build instead of diverging).
grep -Fx 'MOONRAY_USE_OPTIX:BOOL=ON' "${MOONRAY_BUILD_DIR}/CMakeCache.txt"
grep -F 'NVIDIA-OptiX-SDK-7.6.0' "${MOONRAY_BUILD_DIR}/CMakeCache.txt"
grep -F "${BOOST_PYTHON_COMPONENT_NAME}" "${MOONRAY_BUILD_DIR}/CMakeCache.txt"
grep -F '3.13' "${MOONRAY_BUILD_DIR}/CMakeCache.txt"
grep -F '/usr/local/bin/lua' "${MOONRAY_BUILD_DIR}/CMakeCache.txt"

cmake --build "${MOONRAY_BUILD_DIR}" --parallel "${BUILD_JOBS}"
cmake --install "${MOONRAY_BUILD_DIR}" --prefix "${CMAKE_INSTALL_PREFIX}"

# ---------------------------------------------------------------------------
# Post-install: shader_json for the Hydra Ndr plugins; XPU programs check.
# (Environment vars below are process-scoped to this install step only; the
#  image default environment is intentionally left pristine.)
# ---------------------------------------------------------------------------
export PATH="${CMAKE_INSTALL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${CMAKE_INSTALL_PREFIX}/lib:${CMAKE_INSTALL_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
export MOONRAY_ROOT="${CMAKE_INSTALL_PREFIX}"
export RDL2_DSO_PATH="${CMAKE_INSTALL_PREFIX}/rdl2dso.proxy:${CMAKE_INSTALL_PREFIX}/rdl2dso"
export MOONRAY_CLASS_PATH="${CMAKE_INSTALL_PREFIX}/shader_json"
export ARRAS_SESSION_PATH="${CMAKE_INSTALL_PREFIX}/sessions"
export REZ_MOONRAY_ROOT="${CMAKE_INSTALL_PREFIX}"

if find "${CMAKE_INSTALL_PREFIX}" -name OptixGPUPrograms.ptx | grep -q .; then
    echo "XPU shader programs present (OptixGPUPrograms.ptx)"
else
    echo "WARN: OptixGPUPrograms.ptx not found under the install (GPU/XPU path unavailable; auto/vector fallback still works)"
fi

mkdir -p "${CMAKE_INSTALL_PREFIX}/shader_json"
rdl2_json_exporter \
    --out "${CMAKE_INSTALL_PREFIX}/shader_json/" \
    --sparse