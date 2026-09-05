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
# This script adapts to the ASWF moon ray base it runs on. The two relevant
# lines differ sharply and both are supported (shims below only act when their
# condition holds):
#   - CY2025 (aswf/ci-moonray:2025.8): CMake 3.31, USD 25.05 (Ndr present),
#     Boost with asio io_service, usable ispc -> a plain general_build.md run
#     with Ninja; only the OpenUSD cmake-export shim is exercised.
#   - CY2027 (aswf/ci-moonray:2027.1): CMake 4.3, USD 26.08 (Ndr removed),
#     Boost 1.91 (header-only system; asio io_service + resolver::query
#     removed), gcc-toolset-14, unrunnable conan ispc -> the year-specific
#     CMake-4 policy flags, Boost/asio compat, ispc provision, and the
#     keep-going tolerance for the two Ndr-dependent Sdr plugins activate.
#
# Known deviations / findings (kept minimal and local so this script stays
# usable as the ASWF ci-moonray build step; each is flagged upstream):
#   - ASWF OpenUSD cmake exports: stale Conan-cache path hints, stale
#     CONAN_LIB::materialx_ target names, and references to imported targets
#     the deploy never loads. The shim rewrites hints/names, loads what the
#     deploy ships (Ptex only if present), and synthesizes the rest
#     (OpenSubdiv::osdcpu/osdgpu, Ptex::Ptex_dynamic on CY2025).
#   - Generator: the CMake default (Unix Makefiles), matching general_build.md.
#     Ninja rejects v2026.29.1's duplicated DSO JSON custom commands
#     (dso/camera/BakeCamera "defined as an output multiple times") on every
#     CMake tried so far; OMR_CMAKE_GENERATOR=Ninja can override.
#   - CY2027-only: OpenUSD 26.08 removed the Ndr subsystem (folded into Sdr),
#     but MoonRay's two Sdr plugins (and even OpenMoonRay main) still include
#     pxr/usd/ndr/*.h and fail to compile; the build proceeds keep-going and
#     tolerates exactly those two failures (blocker B5d).
#   - CY2027-only: CMake 4 needs -DCMAKE_POLICY_VERSION_MINIMUM=3.5 (vendored
#     FindTBB) and -DCMAKE_POLICY_DEFAULT_CMP0167=NEW (Boost config).
#   - CY2027-only: Boost 1.91 header-only "system" component package and the
#     deprecated asio io_service.hpp/resolver::query compat headers are emitted
#     when absent.
#   - CY2027-only: the ASWF-conan ispc is unrunnable (LLVM-22 runtime omitted,
#     RUNPATH into the deleted conan cache); the official ispc release is
#     provisioned when the deployed one cannot execute (blocker B6).
#   - git-lfs is not shipped by the base image; it is installed so the
#     openmoonray submodules' LFS files can be pulled.
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

# ispc is required by MoonRay's ISPC kernels on Linux (no disable path; the
# DSO fallback branch is the macOS/aarch64 flow). The ASWF-conan ispc in the
# image is linked against an LLVM-22 runtime that the deploy omitted
# (RUNPATH into the deleted conan cache; libclang-cpp.so.22.1 absent), so it
# cannot execute. Provision the official ispc release (LLVM statically
# linked; only glibc NEEDED) when the deployed one is unusable.
if ispc --version >/dev/null 2>&1; then
    echo "ispc OK: $(ispc --version 2>&1 | head -1)"
else
    echo "WARN: deployed ispc unusable ($(ispc --version 2>&1 | head -1 || true)); installing official ispc v1.25.0"
    ISPC_TARBALL="${MOONRAY_BUILD_ROOT}/ispc-v1.25.0-linux.tar.gz"
    curl --location --fail --silent --show-error \
        -o "${ISPC_TARBALL}" \
        https://github.com/ispc/ispc/releases/download/v1.25.0/ispc-v1.25.0-linux.tar.gz
    echo "1667976049abe6653d170de3f8a462799d57981ce46a161ccf59367f1177a028  ${ISPC_TARBALL}" | sha256sum --check -
    tar -xzf "${ISPC_TARBALL}" -C "${MOONRAY_BUILD_ROOT}"
    install -m 0755 "${MOONRAY_BUILD_ROOT}/ispc-v1.25.0-linux/bin/ispc" /usr/local/bin/ispc
    ispc --version
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

# Stale Conan target names in the deployed pxr exports (MaterialX component
# targets are un-namespaced in the ASWF MaterialX package: MaterialXCore, ...;
# Ptex is Conan-named on CY2025 and an imported target on CY2027+).
materialx_conan = re.compile(
    r"CONAN_LIB::materialx_materialx_(?P<c>[A-Za-z0-9]+)_(?P=c)_RELEASE"
)
ptex_conan = re.compile(
    r"CONAN_LIB::ptex_Ptex_(?P<c>[A-Za-z0-9_]+?)_Ptex_RELEASE"
)

for path in files:
    text = path.read_text()
    text, _ = hint.subn(repl, text)
    if (path.name.startswith("pxrTargets")
            or path.name.startswith("pxrConfig")):
        text, _ = materialx_conan.subn(lambda m: m.group("c"), text)
        text, _ = ptex_conan.subn(lambda m: "Ptex::" + m.group("c"), text)
    path.write_text(text)

text = pxr_config.read_text()
includes = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'
if marker not in text:
    block = f"""{marker}
# The deployed pxr exports reference imported targets that consumers must
# provide (the conan deploy does not load them itself). Ptex ships a cmake
# config on some years (CY2027+); on CY2025 it does not, so synthesize it.
find_package(Threads REQUIRED)
if(EXISTS "/usr/local/lib/cmake/Ptex")
    find_package(Ptex CONFIG REQUIRED)
else()
    if(NOT TARGET Ptex::Ptex_dynamic)
        add_library(Ptex::Ptex_dynamic SHARED IMPORTED)
        set_target_properties(Ptex::Ptex_dynamic PROPERTIES
            IMPORTED_LOCATION "/usr/local/lib/libPtex.so"
            INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
    endif()
endif()
find_package(OpenColorIO CONFIG REQUIRED)
find_package(MaterialX CONFIG REQUIRED)
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

# Boost header-only component shims (same deploy-gap class). Boost's "system"
# component is header-only, so the ASWF deploy ships no boost_system-* package
# for it, but arras4_core requests COMPONENTS system. Emit a
# convention-matching component package at the DEPLOYED Boost version
# (1.85.0 on CY2025, 1.91.0 on CY2027), mirroring the deployed
# boost_python-*/boost_python-config*.cmake files.
BOOST_CMAKE = Path("/usr/local/lib/cmake")
_BOOST_VERSION_H = Path("/usr/local/include/boost/version.hpp")
_BV = 108500
if _BOOST_VERSION_H.is_file():
    m = re.search(r"#define BOOST_VERSION\s+(\d+)", _BOOST_VERSION_H.read_text())
    if m:
        _BV = int(m.group(1))
BOOST_CPP = f"{_BV // 100000}.{_BV // 100 % 1000}.{_BV % 100}"
BOOST_VERSION = f"{BOOST_CPP}"
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

# Boost.Asio io_service -> io_context compatibility header. Boost 1.91's asio
# removed the deprecated boost/asio/io_service.hpp (io_service was a typedef
# of io_context since 1.66); MoonRay v2026.29.1's arras4_athena includes the
# vestigial header. Emit the historical alias like older Boost did.
ASIO_SERVICE = Path("/usr/local/include/boost/asio/io_service.hpp")
if not ASIO_SERVICE.exists() and (Path("/usr/local/include/boost/asio").is_dir()):
    ASIO_SERVICE.write_text(
        "#ifndef BOOST_ASIO_IO_SERVICE_HPP\n"
        "#define BOOST_ASIO_IO_SERVICE_HPP\n"
        "// io_service is the deprecated name of io_context (typedef since "
        "Boost.Asio 1.66);\n"
        "// this header exists only for compatibility with code (such as "
        "MoonRay's\n"
        "// arras4_athena) that includes the legacy header.\n"
        '#include <boost/asio/io_context.hpp>\n'
        "namespace boost { namespace asio {\n"
        "using io_service = io_context;\n"
        "} }\n"
        "#endif\n"
    )
    print("Boost.Asio io_service compatibility header emitted")
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

# CMake-4-only policy guards (CY2027+); ignored on CMake 3.x (CY2025-).
if cmake --version | grep -qE '^cmake version (4|5)\.'; then
    OMR_CMAKE_POLICY_ARGS=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POLICY_DEFAULT_CMP0167=NEW)
else
    OMR_CMAKE_POLICY_ARGS=()
fi

cmake \
    -S "${MOONRAY_SOURCE_DIR}" \
    -B "${MOONRAY_BUILD_DIR}" \
    -G "${OMR_CMAKE_GENERATOR:-"Unix Makefiles"}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/usr/local \
    "${OMR_CMAKE_POLICY_ARGS[@]}" \
    -DCUDAToolkit_ROOT=/usr/local/cuda \
    -DLUA_BIN_LUA:FILEPATH=/usr/local/bin/lua \
    -DLUA_BIN_LUAC:FILEPATH=/usr/local/bin/luac \
    -DPYTHON_EXECUTABLE=/usr/local/bin/python${PYTHON_MAJOR_MINOR} \
    -DPython3_EXECUTABLE=/usr/local/bin/python${PYTHON_MAJOR_MINOR} \
    -DPython3_LIBRARY=/usr/local/lib/libpython${PYTHON_MAJOR_MINOR}.so \
    -DPython3_INCLUDE_DIR=/usr/local/include/python${PYTHON_MAJOR_MINOR} \
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
grep -F "${PYTHON_MAJOR_MINOR}" "${MOONRAY_BUILD_DIR}/CMakeCache.txt"
grep -F '/usr/local/bin/lua' "${MOONRAY_BUILD_DIR}/CMakeCache.txt"

# Build everything, keep-going. MoonRay v2026.29.1's two Sdr plugins
# (moonrayShaderParser / moonrayShaderDiscovery) include pxr/usd/ndr/*.h,
# which OpenUSD 26.08 removed when Ndr was folded into Sdr (source-level API
# break; ASWF pins this MoonRay as 3.6.0.1 on the 26.08 stack). They fail to
# compile; every OTHER target must build. The failure set is verified to be
# exactly those two targets and then tolerated for the probe image; the
# blocker (B5d) is recorded centrally.
BUILD_LOG="${MOONRAY_BUILD_ROOT}/build.log"
set +e
# Stream to the build log AND the step output so compiler diagnostics land in
# the workflow artifact even when a target fails.
cmake --build "${MOONRAY_BUILD_DIR}" --parallel "${BUILD_JOBS}" -- -k 2>&1 | tee "${BUILD_LOG}"
build_status=${PIPESTATUS[0]}
set -e
if [ "${build_status}" -ne 0 ]; then
    echo "build exited ${build_status}; verifying all failures are the two Ndr-dependent Sdr plugin targets"
    other_failures=$(grep -E '\*\*\* \[.*\] Error' "${BUILD_LOG}" | grep -v 'moonray_sdr_plugins' || true)
    if [ -n "${other_failures}" ]; then
        echo "UNEXPECTED failing targets:" 1>&2
        echo "${other_failures}" 1>&2
        exit 1
    fi
    echo "only moonray_sdr_plugins targets failed (Ndr removed in OpenUSD 26.08, blocker B5d)"
fi
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