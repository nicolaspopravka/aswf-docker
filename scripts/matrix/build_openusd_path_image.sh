#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project.
# SPDX-License-Identifier: Apache-2.0
#
# Build one OpenUSD matrix image inside a digest-pinned ci-usd base.

set -Eeuo pipefail

mode="${1:-build}"
evidence_root="/opt/openusd-build-evidence"
work_root="/opt/openusd-build-work"
downloads_root="/opt/openusd-downloads"
source_repository="${SOURCE_REPOSITORY:-https://github.com/PixarAnimationStudios/OpenUSD}"
source_url="${source_repository}/archive/refs/tags/v${OPENUSD_VERSION:?missing OPENUSD_VERSION}.tar.gz"

required_names=(
  BUILD_PATH CY OPENUSD_VERSION MATERIALX_VERSION SOURCE_REVISION
  SOURCE_SHA256 SCRIPT_SHA256 EXPECTED_GCC_MAJOR INSTALL_PREFIX
  BUILD_JOBS ASWF_SOURCE_COMMIT WORKFLOW_REVISION
)

for name in "${required_names[@]}"; do
  [[ -n "${!name:-}" ]] || {
    echo "missing required input: ${name}" >&2
    exit 2
  }
done

case "${BUILD_PATH}" in
  pixar-build-usd|aswf-docker-build-usd|aswf-docker-build-usd-matched-mtlx) ;;
  *)
    echo "unsupported build path: ${BUILD_PATH}" >&2
    exit 2
    ;;
esac

if [[ "${BUILD_PATH}" == aswf-docker-build-usd-matched-mtlx ]]; then
  [[ -n "${MATERIALX_SOURCE_SHA256:-}" ]] || {
    echo "missing required input: MATERIALX_SOURCE_SHA256" >&2
    exit 2
  }
fi

case "${CY}" in
  2023|2024|2025|2026|2027) ;;
  *)
    echo "unsupported CY: ${CY}" >&2
    exit 2
    ;;
esac

if [[ "${mode}" == dry-run ]]; then
  printf '%s\n' \
    "build_path=${BUILD_PATH}" \
    "cy=${CY}" \
    "openusd=${OPENUSD_VERSION}" \
    "materialx=${MATERIALX_VERSION}" \
    "materialx_source_sha256=${MATERIALX_SOURCE_SHA256:-preinstalled}" \
    "source_revision=${SOURCE_REVISION}" \
    "source_sha256=${SOURCE_SHA256}" \
    "script_sha256=${SCRIPT_SHA256}" \
    "expected_gcc_major=${EXPECTED_GCC_MAJOR}" \
    "install_prefix=${INSTALL_PREFIX}" \
    "build_jobs=${BUILD_JOBS}" \
    "aswf_source_commit=${ASWF_SOURCE_COMMIT}" \
    "workflow_revision=${WORKFLOW_REVISION}" \
    "source_url=${source_url}"
  exit 0
fi

[[ "${mode}" == build ]] || {
  echo "usage: $0 [build|dry-run]" >&2
  exit 2
}

mkdir -p \
  "${evidence_root}/cmake-cache" \
  "${evidence_root}/runtime" \
  "${work_root}" \
  "${downloads_root}"

status_file="${evidence_root}/build-exit-status.txt"
record_status() {
  status=$?
  trap - EXIT
  printf '%s\n' "${status}" > "${status_file}"
  exit "${status}"
}
trap record_status EXIT

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

record_clean_base() {
  {
    echo "base clean-room assertions"
    for command_name in usdrecord usdcat; do
      if command -v "${command_name}"; then
        echo "unexpected preinstalled command: ${command_name}" >&2
        return 1
      fi
      echo "absent command: ${command_name}"
    done
    if python3 -c 'import pxr' >/dev/null 2>&1; then
      echo "unexpected preinstalled pxr Python package" >&2
      return 1
    fi
    echo "absent Python package: pxr"
    mapfile -t usd_files < <(
      find /usr/local -xdev -type f \
        \( -name 'libusd*.so*' -o -path '*/pxr/__init__.py' \) \
        -print 2>/dev/null
    )
    if ((${#usd_files[@]})); then
      printf 'unexpected preinstalled OpenUSD file: %s\n' "${usd_files[@]}" >&2
      return 1
    fi
    echo "absent OpenUSD libraries and pxr package below /usr/local"
  } > "${evidence_root}/clean-base.txt"
}

select_compiler() {
  toolset_root=""
  if [[ -n "${ASWF_DTS_PREFIX:-}" && -n "${ASWF_DTS_VERSION:-}" ]]; then
    candidate="/opt/rh/${ASWF_DTS_PREFIX}-${ASWF_DTS_VERSION}/root"
    if [[ -x "${candidate}/usr/bin/gcc" && -x "${candidate}/usr/bin/g++" ]]; then
      toolset_root="${candidate}"
      export PATH="${toolset_root}/usr/bin:${PATH}"
      export LD_LIBRARY_PATH="${toolset_root}/usr/lib64:${toolset_root}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    fi
  fi
  export CC
  export CXX
  CC="$(command -v gcc)"
  CXX="$(command -v g++)"
  actual_gcc_major="$("${CC}" -dumpfullversion -dumpversion | cut -d. -f1)"
  [[ "${actual_gcc_major}" == "${EXPECTED_GCC_MAJOR}" ]] || {
    echo "expected GCC ${EXPECTED_GCC_MAJOR}, observed ${actual_gcc_major}" >&2
    return 1
  }
  {
    echo "toolset_root=${toolset_root:-system}"
    echo "CC=${CC}"
    echo "CXX=${CXX}"
    "${CC}" --version
    "${CXX}" --version
    cmake --version
    python3 --version
    echo "nproc=$(nproc)"
    echo "requested_build_jobs=${BUILD_JOBS}"
  } > "${evidence_root}/compiler.txt"
}

record_inputs() {
  {
    printf '%s\n' \
      "build_path=${BUILD_PATH}" \
      "cy=${CY}" \
      "openusd_version=${OPENUSD_VERSION}" \
      "materialx_version=${MATERIALX_VERSION}" \
      "materialx_source_sha256=${MATERIALX_SOURCE_SHA256:-preinstalled}" \
      "source_repository=${source_repository}" \
      "source_url=${source_url}" \
      "source_revision=${SOURCE_REVISION}" \
      "source_sha256=${SOURCE_SHA256}" \
      "script_sha256=${SCRIPT_SHA256}" \
      "expected_gcc_major=${EXPECTED_GCC_MAJOR}" \
      "install_prefix=${INSTALL_PREFIX}" \
      "build_jobs=${BUILD_JOBS}" \
      "aswf_source_commit=${ASWF_SOURCE_COMMIT}" \
      "workflow_revision=${WORKFLOW_REVISION}"
    env | LC_ALL=C sort | grep -E \
      '^(ASWF_|CC=|CXX=|PATH=|LD_LIBRARY_PATH=|PYTHONPATH=|PXR_|CMAKE_)' \
      || true
  } > "${evidence_root}/inputs.txt"
}

build_matched_materialx() {
  materialx_url="https://github.com/AcademySoftwareFoundation/MaterialX/archive/v${MATERIALX_VERSION}.tar.gz"
  materialx_archive="${downloads_root}/materialx-v${MATERIALX_VERSION}.tar.gz"
  materialx_source="${work_root}/MaterialX-${MATERIALX_VERSION}"
  materialx_build="${work_root}/MaterialX-${MATERIALX_VERSION}-build"

  curl --fail --location --retry 3 \
    --output "${materialx_archive}" "${materialx_url}"
  printf '%s  %s\n' "${MATERIALX_SOURCE_SHA256}" "${materialx_archive}" \
    | sha256sum --check

  rm -rf "${materialx_source}" "${materialx_build}"
  mkdir -p "${materialx_source}" "${materialx_build}"
  tar -xzf "${materialx_archive}" --strip-components=1 \
    -C "${materialx_source}"

  # Remove the preinstalled MaterialX 1.39 files before installing 1.38.10 so
  # the diagnostic cannot accidentally compile or run against a mixed prefix.
  rm -rf \
    "${INSTALL_PREFIX}/include/MaterialX"* \
    "${INSTALL_PREFIX}/share/MaterialX" \
    "${INSTALL_PREFIX}/lib/cmake/MaterialX"
  find "${INSTALL_PREFIX}/lib" -maxdepth 1 \
    \( -type f -o -type l \) -name 'libMaterialX*' -delete

  cmake -S "${materialx_source}" -B "${materialx_build}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DCMAKE_CXX_STANDARD=17 \
    -DMATERIALX_BUILD_SHARED_LIBS=ON \
    -DMATERIALX_BUILD_PYTHON=OFF \
    -DMATERIALX_BUILD_VIEWER=OFF \
    -DMATERIALX_BUILD_GRAPH_EDITOR=OFF \
    -DMATERIALX_BUILD_TESTS=OFF \
    -DMATERIALX_TEST_RENDER=OFF \
    -DMATERIALX_BUILD_GEN_MSL=OFF \
    -DMATERIALX_INSTALL_STDLIB_PATH=share/MaterialX/libraries \
    -DMATERIALX_INSTALL_RESOURCES_PATH=share/MaterialX/resources \
    2>&1 | tee "${evidence_root}/materialx-configure.log"
  cmake --build "${materialx_build}" -j"${BUILD_JOBS}" \
    2>&1 | tee "${evidence_root}/materialx-build.log"
  cmake --install "${materialx_build}" \
    2>&1 | tee "${evidence_root}/materialx-install.log"
  materialx_config="${INSTALL_PREFIX}/lib/cmake/MaterialX/MaterialXConfig.cmake"
  cp "${materialx_config}" "${evidence_root}/MaterialXConfig.cmake.original"
  sed -i \
    -e 's#${PACKAGE_PREFIX_DIR}/libraries#${PACKAGE_PREFIX_DIR}/share/MaterialX/libraries#g' \
    "${materialx_config}"
  diff -u "${evidence_root}/MaterialXConfig.cmake.original" \
    "${materialx_config}" \
    > "${evidence_root}/MaterialXConfig.cmake.patch" || config_diff_status=$?
  [[ "${config_diff_status:-0}" == 1 ]]
  grep -Fq \
    '${PACKAGE_PREFIX_DIR}/share/MaterialX/libraries' \
    "${materialx_config}"
  [[ -d "${INSTALL_PREFIX}/share/MaterialX/libraries" ]]
  grep -n -E 'MATERIALX_(BASE|STDLIB|PYTHON|RESOURCES)_DIR' \
    "${materialx_config}" \
    | tee "${evidence_root}/MaterialXConfig-paths.txt"
  printf '%s  %s\n' "${MATERIALX_SOURCE_SHA256}" "${materialx_url}" \
    > "${evidence_root}/materialx-source-sha256.txt"
}

download_source() {
  source_archive="$1"
  curl --fail --location --retry 3 \
    --output "${source_archive}" "${source_url}"
  printf '%s  %s\n' "${SOURCE_SHA256}" "${source_archive}" \
    | sha256sum --check
  printf '%s  %s\n' "${SOURCE_SHA256}" "${source_url}" \
    > "${evidence_root}/source-sha256.txt"
}

preserve_cmake_caches() {
  search_root="$1"
  while IFS= read -r -d '' cache; do
    relative="${cache#${search_root}/}"
    destination="${evidence_root}/cmake-cache/${relative//\//__}"
    cp "${cache}" "${destination}"
  done < <(find "${search_root}" -type f -name CMakeCache.txt -print0)
  find "${evidence_root}/cmake-cache" -type f -print \
    | LC_ALL=C sort > "${evidence_root}/cmake-cache-files.txt"
}

build_pixar() {
  source_archive="${downloads_root}/openusd-v${OPENUSD_VERSION}.tar.gz"
  source_root="${work_root}/OpenUSD-${OPENUSD_VERSION}"
  download_source "${source_archive}"
  rm -rf "${source_root}" "${INSTALL_PREFIX}"
  mkdir -p "${source_root}" "${INSTALL_PREFIX}"
  tar -xzf "${source_archive}" --strip-components=1 -C "${source_root}"

  pixar_script="${source_root}/build_scripts/build_usd.py"
  actual_script_sha="$(sha256_file "${pixar_script}")"
  [[ "${actual_script_sha}" == "${SCRIPT_SHA256}" ]] || {
    echo "build_usd.py SHA-256 mismatch: ${actual_script_sha}" >&2
    return 1
  }
  cp "${pixar_script}" "${evidence_root}/build_usd.py.original"

  if [[ "${OPENUSD_VERSION}" == 23.08 || "${OPENUSD_VERSION}" == 24.08 ]]; then
    python3 - "${pixar_script}" "${OPENUSD_VERSION}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
replacements = {
    "23.08": (
        "https://boostorg.jfrog.io/artifactory/main/release/"
        "1.78.0/source/boost_1_78_0.zip",
        "https://archives.boost.io/release/1.78.0/source/boost_1_78_0.zip",
        3,
    ),
    "24.08": (
        "https://boostorg.jfrog.io/artifactory/main/release/"
        "1.82.0/source/boost_1_82_0.zip",
        "https://archives.boost.io/release/1.82.0/source/boost_1_82_0.zip",
        1,
    ),
}
old, new, expected_count = replacements[version]
text = path.read_text()
if text.count(old) != expected_count:
    raise SystemExit(
        f"expected {expected_count} obsolete Boost URL(s), found "
        f"{text.count(old)}"
    )
path.write_text(text.replace(old, new))
PY
    diff -u "${evidence_root}/build_usd.py.original" "${pixar_script}" \
      > "${evidence_root}/build_usd.py.boost-url.patch" || diff_status=$?
    [[ "${diff_status:-0}" == 1 ]]
  fi
  cp "${pixar_script}" "${evidence_root}/build_usd.py.executed"
  sha256_file "${pixar_script}" > "${evidence_root}/build_usd.py.executed.sha256"

  command=(
    python3 "${pixar_script}"
    -j "${BUILD_JOBS}"
    --no-embree
    --no-prman
    --no-usdview
    --no-examples
    --no-tutorials
    --no-tests
    --no-docs
    --no-python-docs
    --build-args
    "USD,-DCMAKE_IGNORE_PATH=/usr/local/lib/cmake/TBB -DTBB_ROOT_DIR=${INSTALL_PREFIX} -DTBB_INCLUDE_DIR=${INSTALL_PREFIX}/include -DTBB_LIBRARY=${INSTALL_PREFIX}/lib/libtbb.so -DTBB_tbb_LIBRARY_RELEASE=${INSTALL_PREFIX}/lib/libtbb.so"
    --materialx
    "${INSTALL_PREFIX}"
  )
  printf '%q ' "${command[@]}" > "${evidence_root}/build-argv.txt"
  printf '\n' >> "${evidence_root}/build-argv.txt"
  "${command[@]}" 2>&1 | tee "${evidence_root}/build.log"
  preserve_cmake_caches "${INSTALL_PREFIX}"
  rm -rf "${INSTALL_PREFIX}/build" "${INSTALL_PREFIX}/src"
}

prepare_cy2024_patch_shim() {
  patch_url="https://github.com/PixarAnimationStudios/OpenUSD/compare/1a85ea7262b387a893271101069cc1fef87b838c...ebd684d830ebb869a5f99f54938b8957dcca12c6.diff"
  patch_sha="585a5f6904eeb2c664fecd7ab6ab5c9606ae99b3d5c0c52ab36832f8c7c7b94d"
  patch_file="${downloads_root}/openusd-pr3159.diff"
  curl --fail --location --retry 3 \
    --output "${patch_file}" "${patch_url}"
  printf '%s  %s\n' "${patch_sha}" "${patch_file}" | sha256sum --check
  mkdir -p "${work_root}/curl-shim"
  cat > "${work_root}/curl-shim/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "${argument}" == "https://patch-diff.githubusercontent.com/raw/PixarAnimationStudios/OpenUSD/pull/3159.diff" ]]; then
    cat /opt/openusd-downloads/openusd-pr3159.diff
    exit 0
  fi
done
exec /usr/bin/curl "$@"
SHIM
  chmod 0755 "${work_root}/curl-shim/curl"
  export PATH="${work_root}/curl-shim:${PATH}"
  {
    echo "${patch_sha}  ${patch_url}"
    sha256sum "${work_root}/curl-shim/curl"
  } > "${evidence_root}/cy2024-patch-inputs.txt"
}

build_aswf() {
  helper="/opt/openusd-matrix/aswf-build_usd.sh"
  actual_script_sha="$(sha256_file "${helper}")"
  [[ "${actual_script_sha}" == "${SCRIPT_SHA256}" ]] || {
    echo "ASWF build_usd.sh SHA-256 mismatch: ${actual_script_sha}" >&2
    return 1
  }
  cp "${helper}" "${evidence_root}/aswf-build_usd.sh"
  printf '%s\n' "bash ${helper}" > "${evidence_root}/build-argv.txt"

  source_archive="${downloads_root}/usd-${OPENUSD_VERSION}.tar.gz"
  download_source "${source_archive}"
  [[ "${OPENUSD_VERSION}" != 24.08 ]] || prepare_cy2024_patch_shim

  export ASWF_OPENUSD_VERSION="${OPENUSD_VERSION}"
  export ASWF_MATERIALX_VERSION="${MATERIALX_VERSION}"
  export ASWF_INSTALL_PREFIX="${INSTALL_PREFIX}"
  export DOWNLOADS_DIR="${downloads_root}"
  export USD_EXTRA_ARGS=""
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1
  python3 -m pip freeze --all | LC_ALL=C sort \
    > "${evidence_root}/pip-before.txt"
  (
    cd "${work_root}"
    bash "${helper}"
  ) 2>&1 | tee "${evidence_root}/build.log"
  python3 -m pip freeze --all | LC_ALL=C sort \
    > "${evidence_root}/pip-after.txt"
  diff -u "${evidence_root}/pip-before.txt" "${evidence_root}/pip-after.txt" \
    > "${evidence_root}/pip-changes.patch" || diff_status=$?
  [[ "${diff_status:-0}" == 0 || "${diff_status:-0}" == 1 ]]
  printf '%s\n' \
    "The stock ASWF helper removes OpenUSD-${OPENUSD_VERSION} after install." \
    "No post-build CMake cache is claimed for this path." \
    > "${evidence_root}/cmake-cache-unavailable.txt"
}

configure_runtime() {
  export PATH="${INSTALL_PREFIX}/bin:${PATH}"
  export LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export PYTHONPATH="${INSTALL_PREFIX}/lib/python"
  export PXR_PLUGINPATH_NAME="${INSTALL_PREFIX}/plugin/usd"
  export PXR_MTLX_STDLIB_SEARCH_PATHS="${INSTALL_PREFIX}/share/MaterialX"
}

record_runtime() {
  command -v usdrecord > "${evidence_root}/runtime/usdrecord-path.txt"
  command -v usdcat > "${evidence_root}/runtime/usdcat-path.txt"
  case "$(cat "${evidence_root}/runtime/usdrecord-path.txt")" in
    "${INSTALL_PREFIX}"/*) ;;
    *)
      echo "usdrecord did not resolve inside ${INSTALL_PREFIX}" >&2
      return 1
      ;;
  esac
  python3 - <<'PY' > "${evidence_root}/runtime/python-pxr.txt"
from pxr import Plug, Usd
import pxr
print("pxr_file=" + pxr.__file__)
print("usd_version=" + ".".join(str(part) for part in Usd.GetVersion()))
registry = Plug.Registry()
plugins = sorted(plugin.name for plugin in registry.GetAllPlugins())
print("plugin_count=" + str(len(plugins)))
print("plugin_names=" + ",".join(plugins))
PY
  grep -F "pxr_file=${INSTALL_PREFIX}/" \
    "${evidence_root}/runtime/python-pxr.txt"
  grep -R -l -F '"HdStormRendererPlugin"' \
    "${INSTALL_PREFIX}/plugin/usd" "${INSTALL_PREFIX}/lib/usd" \
    > "${evidence_root}/runtime/storm-plugin-metadata.txt"

  usdrecord --help > "${evidence_root}/runtime/usdrecord-help.txt"
  usdcat --version > "${evidence_root}/runtime/usdcat-version.txt" 2>&1 || true
  find "${INSTALL_PREFIX}" -xdev -type f -printf '%P\t%s\n' \
    | LC_ALL=C sort > "${evidence_root}/install-inventory.txt"
  find "${INSTALL_PREFIX}" -type f -name plugInfo.json -print \
    | LC_ALL=C sort > "${evidence_root}/runtime/plugin-info-files.txt"
  find "${INSTALL_PREFIX}" -type f \
    \( -name 'libusd*.so*' -o -name 'libhd*.so*' -o -name 'libusd*.dylib' \) \
    -print | LC_ALL=C sort > "${evidence_root}/runtime/openusd-libraries.txt"
  while IFS= read -r library; do
    [[ -n "${library}" ]] || continue
    {
      echo "=== ${library}"
      ldd "${library}" || true
      readelf -d "${library}" || true
    } >> "${evidence_root}/runtime/library-dependencies.txt"
  done < "${evidence_root}/runtime/openusd-libraries.txt"

  materialx_header="$(find "${INSTALL_PREFIX}" -type f \
    -path '*/MaterialXCore/Generated.h' -print -quit)"
  [[ -n "${materialx_header}" ]] || {
    echo "MaterialX Generated.h not found below ${INSTALL_PREFIX}" >&2
    return 1
  }
  {
    echo "header=${materialx_header}"
    grep -E 'MATERIALX_(MAJOR|MINOR|BUILD)_VERSION' "${materialx_header}" || true
  } > "${evidence_root}/runtime/materialx-version.txt"
  {
    printf 'PATH=%q\n' "${PATH}"
    printf 'LD_LIBRARY_PATH=%q\n' "${LD_LIBRARY_PATH}"
    printf 'PYTHONPATH=%q\n' "${PYTHONPATH}"
    printf 'PXR_PLUGINPATH_NAME=%q\n' "${PXR_PLUGINPATH_NAME}"
    printf 'PXR_MTLX_STDLIB_SEARCH_PATHS=%q\n' "${PXR_MTLX_STDLIB_SEARCH_PATHS}"
  } > "${evidence_root}/runtime/environment.sh"
  (
    cd "${evidence_root}"
    sha256sum \
      runtime/usdrecord-path.txt \
      runtime/python-pxr.txt \
      install-inventory.txt \
      > runtime/evidence-sha256.txt
  )
}

record_clean_base
select_compiler
record_inputs
if [[ -d "${INSTALL_PREFIX}" ]]; then
  find "${INSTALL_PREFIX}" -xdev -type f -printf '%P\t%s\n' 2>/dev/null \
    | LC_ALL=C sort > "${evidence_root}/prefix-before.txt"
else
  : > "${evidence_root}/prefix-before.txt"
fi

[[ "${BUILD_PATH}" != aswf-docker-build-usd-matched-mtlx ]] \
  || build_matched_materialx

case "${BUILD_PATH}" in
  pixar-build-usd) build_pixar ;;
  aswf-docker-build-usd|aswf-docker-build-usd-matched-mtlx) build_aswf ;;
esac

configure_runtime
record_runtime
printf '0\n' > "${status_file}"
trap - EXIT
