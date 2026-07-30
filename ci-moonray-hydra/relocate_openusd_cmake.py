#!/usr/bin/env python3
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Relocate only the installed OpenUSD CMake exports in the ASWF image."""

from pathlib import Path
import re


PXR_CONFIG = Path("/usr/local/pxrConfig.cmake")
PXR_TARGETS = sorted(Path("/usr/local/cmake").glob("pxrTargets*.cmake"))
REQUIRED_LIBRARIES = (
    Path("/usr/local/lib/libosdCPU.so"),
    Path("/usr/local/lib/libosdGPU.so"),
    Path("/usr/local/lib/libOpenColorIO.so"),
    Path("/usr/local/lib/libPtex.so"),
)
CONAN_PREFIX = re.compile(
    r"/opt/conan_home/d/(?:b/)?"
    r"[^/\"; )]+(?:/[^/\"; )]+)?/p"
)
MATERIALX_CONAN_TARGET = re.compile(
    r"CONAN_LIB::materialx_materialx_"
    r"(?P<component>MaterialX[A-Za-z0-9]+)_"
    r"(?P=component)_RELEASE"
)
PTEX_CONAN_TARGET = "CONAN_LIB::ptex_Ptex_Ptex_dynamic_Ptex_RELEASE"
DEPENDENCY_MARKER = "# ASWF deployed-image dependency relocation for OpenMoonRay"
TARGETS_INCLUDE = 'include("${PXR_CMAKE_DIR}/cmake/pxrTargets.cmake")'


def main() -> int:
    if not PXR_TARGETS:
        raise SystemExit("no installed pxrTargets CMake exports found")
    files = [PXR_CONFIG, *PXR_TARGETS]
    missing = [
        str(path)
        for path in (*files, *REQUIRED_LIBRARIES)
        if not path.is_file()
    ]
    if missing:
        raise SystemExit(f"missing OpenUSD CMake exports: {missing}")

    replacement_count = 0
    materialx_target_count = 0
    ptex_target_count = 0
    observed_prefixes: set[str] = set()
    observed_targets: set[str] = set()

    for path in files:
        text = path.read_text()
        prefixes = set(CONAN_PREFIX.findall(text))
        targets = set(MATERIALX_CONAN_TARGET.findall(text))
        observed_prefixes.update(prefixes)
        observed_targets.update(targets)
        text, replaced = CONAN_PREFIX.subn("/usr/local", text)
        replacement_count += replaced
        text, replaced_targets = MATERIALX_CONAN_TARGET.subn(
            lambda match: match.group("component"), text
        )
        materialx_target_count += replaced_targets
        ptex_replacements = text.count(PTEX_CONAN_TARGET)
        text = text.replace(PTEX_CONAN_TARGET, "Ptex::Ptex_dynamic")
        ptex_target_count += ptex_replacements
        path.write_text(text)

    config = PXR_CONFIG.read_text()
    if DEPENDENCY_MARKER not in config:
        if TARGETS_INCLUDE not in config:
            raise SystemExit("cannot locate pxrTargets include in pxrConfig.cmake")
        dependency_block = f"""{DEPENDENCY_MARKER}
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

if(NOT TARGET OpenColorIO::OpenColorIO)
    add_library(OpenColorIO::OpenColorIO SHARED IMPORTED)
    set_target_properties(OpenColorIO::OpenColorIO PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libOpenColorIO.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()

if(NOT TARGET Ptex::Ptex_dynamic)
    add_library(Ptex::Ptex_dynamic SHARED IMPORTED)
    set_target_properties(Ptex::Ptex_dynamic PROPERTIES
        IMPORTED_LOCATION "/usr/local/lib/libPtex.so"
        INTERFACE_INCLUDE_DIRECTORIES "/usr/local/include")
endif()

{TARGETS_INCLUDE}"""
        config = config.replace(TARGETS_INCLUDE, dependency_block, 1)
        PXR_CONFIG.write_text(config)

    final_text = "\n".join(path.read_text() for path in files)
    if "/opt/conan_home/" in final_text:
        remaining = sorted(
            set(re.findall(r"/opt/conan_home/[^\"; )\n]+", final_text))
        )
        raise SystemExit(
            f"stale Conan-cache references remain in OpenUSD exports: {remaining}"
        )
    unexpected_targets = sorted(set(re.findall(r"CONAN_LIB::[A-Za-z0-9_]+", final_text)))
    if unexpected_targets:
        raise SystemExit(f"unmapped Conan targets remain: {unexpected_targets}")
    if not observed_prefixes:
        raise SystemExit("expected stale Conan-cache prefixes were not found")
    if not observed_targets:
        raise SystemExit("expected stale MaterialX Conan target was not found")

    print("OpenUSD CMake relocation shim applied")
    print(f"files={','.join(str(path) for path in files)}")
    print(f"path_replacements={replacement_count}")
    print(f"materialx_target_replacements={materialx_target_count}")
    print(f"ptex_target_replacements={ptex_target_count}")
    for prefix in sorted(observed_prefixes):
        print(f"relocated_prefix={prefix}")
    for target in sorted(observed_targets):
        print(f"materialx_component={target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
