#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build OpenMoonRay into the pristine stack image.
#
# Canonical reference: the official Rocky 9 container build
#   https://docs.openmoonray.org/getting-started/installation/building-moonray/rocky9_container_build
#
# Step mapping (the aswf/ci-moonray base already satisfies Steps 1-2):
#   Step 1  install_packages.sh --nocuda   -> satisfied by the base image
#   Step 2  building/Rocky9 dependencies   -> deployed under ${ASWF_INSTALL_PREFIX}
#   Step 3  this script: source -> configure -> build -> install
#
# Documented deltas (environment-bound, not workarounds):
#   - -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}": ASWF deps live there, not
#     /usr (matches the aswf-docker build-script convention, e.g. build_alembic.sh).
#   - -DBUILD_QT_APPS=NO: the MoonRay cmake defaults it to YES when
#     REZ_QT_MAJOR_VERSION is unset (it is, in the base); we do not build the GUI.
#   - The cmake --install --prefix is required because OpenMoonRay's CMakeLists
#     remaps CMAKE_INSTALL_PREFIX=/usr/local to <source>/release at configure time.
#
# No workarounds live here. When this build fails on an ASWF-defect, the fix is
# added as a separate RUN step in Dockerfile.pristine, driven by that evidence.
set -euo pipefail

# --- Required input -------------------------------------------------------
MOONRAY_TAG="${MOONRAY_TAG:?MOONRAY_TAG required, e.g. v2026.29.1}"

# --- Optional inputs ------------------------------------------------------
MOONRAY_REPO_URL="${MOONRAY_REPO_URL:-https://github.com/OpenMoonRay/openmoonray.git}"
CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-${ASWF_INSTALL_PREFIX:-/usr/local}}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "${BUILD_ROOT}"' EXIT
MOONRAY_SRC="${BUILD_ROOT}/src"
MOONRAY_BUILD="${BUILD_ROOT}/build"

# --- Step 3a: source ------------------------------------------------------
# The superproject references 19 submodules; some track files via LFS.
git clone --branch "${MOONRAY_TAG}" --recurse-submodules \
    "${MOONRAY_REPO_URL}" "${MOONRAY_SRC}"
git -C "${MOONRAY_SRC}" rev-parse HEAD   # recorded for evidence; not asserted
git -C "${MOONRAY_SRC}" lfs pull

# --- Optional: candidate patches ------------------------------------------
# MOONRAY_PATCHES_DIR, when set, is applied to the checked-out superproject
# before configure, so a candidate fix is actually built into the image. It
# exists so a candidate can be validated on a real build without editing this
# script or the upstream source in place; the default path applies nothing.
#
# Each patch goes to whichever tree owns the files it names: hdMoonray and
# moonray_sdr_plugins are git submodules, so a superproject-rooted `git apply`
# cannot see inside them.
if [ -n "${MOONRAY_PATCHES_DIR:-}" ]; then
    for patch in "${MOONRAY_PATCHES_DIR}"/*.patch; do
        [ -f "$patch" ] || continue
        applied=0
        for tree in "${MOONRAY_SRC}" "${MOONRAY_SRC}/moonray/hydra/hdMoonray" \
                    "${MOONRAY_SRC}/moonray/hydra/moonray_sdr_plugins"; do
            [ -d "$tree" ] || continue
            if ! git -C "$tree" apply --check "$patch" 2>/dev/null; then
                continue
            fi
            echo "applying candidate patch to ${tree#"${MOONRAY_SRC}"/}: $(basename "$patch")"
            git -C "$tree" apply --verbose "$patch"
            applied=1
            break
        done
        if [ "$applied" != "1" ]; then
            echo "ERROR: candidate patch applies to no tree: ${patch}" >&2
            exit 1
        fi
    done
    echo "evidence: superproject $(git -C "${MOONRAY_SRC}" rev-parse HEAD), hdMoonray $(git -C "${MOONRAY_SRC}/moonray/hydra/hdMoonray" rev-parse HEAD)"
    # Diagnostic branch only: prove that the applied candidate equals PR #19.
    hd_source="${MOONRAY_SRC}/moonray/hydra/hdMoonray"
    test "$(git -C "$hd_source" rev-parse HEAD)" = 986121dbb8817237c02a254d0c4470b5eb820f9e
    git -C "$hd_source" fetch https://github.com/nicolaspopravka/hdMoonray.git \
        6fd4b8e7939c8d8c0f131f315ab24670277186b1
    git -C "$hd_source" diff --exit-code FETCH_HEAD --
    echo "Verified exact hdMoonray PR #19 source: 6fd4b8e7939c8d8c0f131f315ab24670277186b1"
fi

# --- Step 3b: configure ---------------------------------------------------
cmake -S "${MOONRAY_SRC}" -B "${MOONRAY_BUILD}" \
    -DCMAKE_PREFIX_PATH="${ASWF_INSTALL_PREFIX}" \
    -DPYTHON_EXECUTABLE=python3 \
    -DBOOST_PYTHON_COMPONENT_NAME="python${ASWF_PYTHON_MAJOR_MINOR_VERSION//./}" \
    -DABI_VERSION=0 \
    -DBUILD_QT_APPS=NO \
    -DMOONRAY_USE_OPTIX=NO

# --- Step 3c: build -------------------------------------------------------
cmake --build "${MOONRAY_BUILD}" --parallel "${BUILD_JOBS}"

# --- Step 3d: install -----------------------------------------------------
cmake --install "${MOONRAY_BUILD}" --prefix "${CMAKE_INSTALL_PREFIX}"

echo "OpenMoonRay ${MOONRAY_TAG} installed under ${CMAKE_INSTALL_PREFIX}"
