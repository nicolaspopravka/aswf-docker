#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly evidence_root=/evidence
readonly install_root=/opt/MoonRay/installs/openmoonray
mkdir -p "${evidence_root}"

test -f "${install_root}/share/openmoonray/build-evidence.txt"
test -f "${install_root}/share/openmoonray/CMakeCache.txt"
test -f "${install_root}/share/openmoonray/submodules.txt"

cp "${install_root}/share/openmoonray/build-evidence.txt" \
    "${evidence_root}/build-evidence.txt"
cp "${install_root}/share/openmoonray/CMakeCache.txt" \
    "${evidence_root}/CMakeCache.txt"
cp "${install_root}/share/openmoonray/submodules.txt" \
    "${evidence_root}/submodules.txt"

find "${install_root}" -type f -o -type l \
    | sort \
    | tee "${evidence_root}/installed-files.txt"

for plugin_name in \
    hd_moonray.so \
    hd_moonray_debug.so \
    moonrayShaderDiscovery.so \
    moonrayShaderParser.so
do
    plugin_path="$(
        find "${install_root}" -type f -name "${plugin_name}" -print -quit
    )"
    test -n "${plugin_path}"
    printf '%s\t%s\n' "${plugin_name}" "${plugin_path}" \
        | tee -a "${evidence_root}/required-plugins.txt"
    ldd "${plugin_path}" \
        | tee "${evidence_root}/ldd-${plugin_name}.txt"
    if ldd "${plugin_path}" | grep -F 'not found'; then
        echo "Unresolved dependency in ${plugin_path}" >&2
        exit 1
    fi
done

usdrecord --help 2>&1 | tee "${evidence_root}/usdrecord-help.txt"
grep -F 'Moonray' "${evidence_root}/usdrecord-help.txt"

find "${install_root}" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    > "${evidence_root}/installed-files.sha256"

python3 --version 2>&1 | tee "${evidence_root}/python-version.txt"
cmake --version | tee "${evidence_root}/cmake-version.txt"
cc --version | tee "${evidence_root}/compiler-version.txt"
