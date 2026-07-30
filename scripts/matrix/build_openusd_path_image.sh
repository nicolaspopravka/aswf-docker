#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project.
# SPDX-License-Identifier: Apache-2.0
#
# Build one OpenUSD matrix image inside its digest-pinned build-path base.

set -Eeuo pipefail

mode="${1:-build}"
evidence_root="/opt/openusd-build-evidence"
work_root="/opt/openusd-build-work"
downloads_root="/opt/openusd-downloads"
source_repository="${SOURCE_REPOSITORY:-https://github.com/PixarAnimationStudios/OpenUSD}"
source_url="${source_repository}/archive/refs/tags/v${OPENUSD_VERSION:?missing OPENUSD_VERSION}.tar.gz"
python_source_url=""
debug_build="${DEBUG_BUILD:-0}"

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

if [[ "${BUILD_PATH}" == pixar-build-usd ]]; then
  : "${PYTHON_VERSION:?missing PYTHON_VERSION for Pixar build}"
  : "${PYTHON_SHA256:?missing PYTHON_SHA256 for Pixar build}"
  python_source_url="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
fi

case "${BUILD_PATH}" in
  pixar-build-usd|aswf-docker-build-usd) ;;
  *)
    echo "unsupported build path: ${BUILD_PATH}" >&2
    exit 2
    ;;
esac

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
    "python=${PYTHON_VERSION:-base-image}" \
    "python_sha256=${PYTHON_SHA256:-base-image}" \
    "python_source_url=${python_source_url:-base-image}" \
    "source_revision=${SOURCE_REVISION}" \
    "source_sha256=${SOURCE_SHA256}" \
    "script_sha256=${SCRIPT_SHA256}" \
    "expected_gcc_major=${EXPECTED_GCC_MAJOR}" \
    "install_prefix=${INSTALL_PREFIX}" \
    "build_jobs=${BUILD_JOBS}" \
    "aswf_source_commit=${ASWF_SOURCE_COMMIT}" \
    "workflow_revision=${WORKFLOW_REVISION}" \
    "debug_build=${debug_build}" \
    "ptex_buffer_patch_sha256=${PTEX_BUFFER_PATCH_SHA256:-none}" \
    "build_variant=$([[ "${debug_build}" == 1 ]] && echo relwithdebuginfo || echo release)" \
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
    if [[ "${BUILD_PATH}" == pixar-build-usd ]]; then
      if [[ -n "${ASWF_OPENUSD_VERSION:-}" ]]; then
        echo "unexpected ci-usd OpenUSD environment in Pixar base" >&2
        return 1
      fi
      echo "absent ASWF_OPENUSD_VERSION: Pixar base is not ci-usd"
    else
      [[ "${ASWF_OPENUSD_VERSION:-}" == "${OPENUSD_VERSION}" ]] || {
        echo "ASWF ci-usd version mismatch: ${ASWF_OPENUSD_VERSION:-unset}" >&2
        return 1
      }
      echo "matching ASWF_OPENUSD_VERSION=${ASWF_OPENUSD_VERSION}"
    fi
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
    echo -n "base_python3="
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
      "python_version=${PYTHON_VERSION:-base-image}" \
      "python_source_url=${python_source_url:-base-image}" \
      "python_sha256=${PYTHON_SHA256:-base-image}" \
      "source_repository=${source_repository}" \
      "source_url=${source_url}" \
      "source_revision=${SOURCE_REVISION}" \
      "source_sha256=${SOURCE_SHA256}" \
      "script_sha256=${SCRIPT_SHA256}" \
      "expected_gcc_major=${EXPECTED_GCC_MAJOR}" \
      "install_prefix=${INSTALL_PREFIX}" \
      "build_jobs=${BUILD_JOBS}" \
      "aswf_source_commit=${ASWF_SOURCE_COMMIT}" \
      "workflow_revision=${WORKFLOW_REVISION}" \
      "debug_build=${debug_build}"
    if [[ -n "${PTEX_BUFFER_PATCH_SHA256:-}" ]]; then
      echo "ptex_buffer_patch_sha256=${PTEX_BUFFER_PATCH_SHA256}"
    fi
    env | LC_ALL=C sort | grep -E \
      '^(ASWF_|CC=|CXX=|PATH=|LD_LIBRARY_PATH=|PYTHONPATH=|PXR_|CMAKE_)' \
      || true
  } > "${evidence_root}/inputs.txt"
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

install_pixar_python() {
  python_archive="${downloads_root}/Python-${PYTHON_VERSION}.tgz"
  python_source_root="${work_root}/Python-${PYTHON_VERSION}"
  curl --fail --location --retry 3 \
    --output "${python_archive}" "${python_source_url}"
  printf '%s  %s\n' "${PYTHON_SHA256}" "${python_archive}" \
    | sha256sum --check
  printf '%s  %s\n' "${PYTHON_SHA256}" "${python_source_url}" \
    > "${evidence_root}/python-source-sha256.txt"

  rm -rf "${python_source_root}"
  mkdir -p "${python_source_root}"
  tar -xzf "${python_archive}" --strip-components=1 -C "${python_source_root}"
  python_configure=(
    "${python_source_root}/configure"
    "--prefix=${INSTALL_PREFIX}"
    --enable-shared
    --with-ensurepip=no
  )
  printf '%q ' "${python_configure[@]}" \
    > "${evidence_root}/python-configure-argv.txt"
  printf '\n' >> "${evidence_root}/python-configure-argv.txt"
  (
    cd "${python_source_root}"
    "${python_configure[@]}"
  ) 2>&1 | tee "${evidence_root}/python-configure.log"
  make -C "${python_source_root}" -j "${BUILD_JOBS}" \
    2>&1 | tee "${evidence_root}/python-build.log"
  make -C "${python_source_root}" install \
    2>&1 | tee "${evidence_root}/python-install.log"

  export PATH="${INSTALL_PREFIX}/bin:${PATH}"
  export LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  hash -r
  pixar_python="${INSTALL_PREFIX}/bin/python3"
  [[ -x "${pixar_python}" ]]
  observed_python="$("${pixar_python}" -c \
    'import platform; print(platform.python_version())')"
  [[ "${observed_python}" == "${PYTHON_VERSION}" ]] || {
    echo "expected Python ${PYTHON_VERSION}, observed ${observed_python}" >&2
    return 1
  }
  {
    echo "executable=${pixar_python}"
    "${pixar_python}" -VV
    "${pixar_python}" -c \
      'import platform, sys, sysconfig; print("platform=" + platform.platform()); print("prefix=" + sys.prefix); print("libdir=" + str(sysconfig.get_config_var("LIBDIR"))); print("ldlibrary=" + str(sysconfig.get_config_var("LDLIBRARY")))'
  } > "${evidence_root}/python-runtime.txt"
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
  install_pixar_python
  pixar_python="${INSTALL_PREFIX}/bin/python3"
  source_archive="${downloads_root}/openusd-v${OPENUSD_VERSION}.tar.gz"
  source_root="${work_root}/OpenUSD-${OPENUSD_VERSION}"
  download_source "${source_archive}"
  rm -rf "${source_root}"
  mkdir -p "${source_root}" "${INSTALL_PREFIX}"
  tar -xzf "${source_archive}" --strip-components=1 -C "${source_root}"

  if [[ -n "${PTEX_BUFFER_PATCH_SHA256:-}" ]]; then
    ptex_buffer_patch="/opt/openusd-matrix/openusd-ptex-buffer-size-overflow.patch"
    ptex_buffer_test="/opt/openusd-matrix/test_openusd_ptex_buffer_size.cpp"
    ptex_validator="/opt/openusd-matrix/validate_ptex_file.cpp"
    printf '%s  %s\n' \
      "${PTEX_BUFFER_PATCH_SHA256}" "${ptex_buffer_patch}" \
      | sha256sum --check
    sha256sum \
      "${ptex_buffer_patch}" \
      "${ptex_buffer_test}" \
      "${ptex_validator}" \
      > "${evidence_root}/ptex-diagnostic-inputs.sha256"
    cp "${ptex_buffer_patch}" \
      "${evidence_root}/openusd-ptex-buffer-size-overflow.patch"
    (
      cd "${source_root}"
      patch -p1 --fuzz=0 < "${ptex_buffer_patch}"
    ) 2>&1 | tee "${evidence_root}/openusd-ptex-buffer-patch.log"
    "${CXX}" -std=c++17 -Wall -Wextra -Werror \
      -I "${source_root}" \
      "${ptex_buffer_test}" \
      -o "${work_root}/test_openusd_ptex_buffer_size"
    "${work_root}/test_openusd_ptex_buffer_size" \
      | tee "${evidence_root}/openusd-ptex-buffer-size-test.log"
  fi

  pixar_script="${source_root}/build_scripts/build_usd.py"
  actual_script_sha="$(sha256_file "${pixar_script}")"
  [[ "${actual_script_sha}" == "${SCRIPT_SHA256}" ]] || {
    echo "build_usd.py SHA-256 mismatch: ${actual_script_sha}" >&2
    return 1
  }
  cp "${pixar_script}" "${evidence_root}/build_usd.py.original"

  if [[ "${OPENUSD_VERSION}" == 23.08 || "${OPENUSD_VERSION}" == 24.08 ]]; then
    "${pixar_python}" - "${pixar_script}" "${OPENUSD_VERSION}" <<'PY'
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

  build_variant_args=()
  feature_args=(--materialx)
  if [[ "${debug_build}" == 1 ]]; then
    export CFLAGS="${CFLAGS:+${CFLAGS} }-fno-omit-frame-pointer"
    export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-fno-omit-frame-pointer"
    build_variant_args=(--build-variant relwithdebuginfo)
    feature_args+=(--ptex --openvdb)
  fi

  command=(
    "${pixar_python}" "${pixar_script}"
    -j "${BUILD_JOBS}"
    --no-embree
    --no-prman
    --no-usdview
    --no-examples
    --no-tutorials
    --no-tests
    --no-docs
    --no-python-docs
    "${build_variant_args[@]}"
    --build-args
    "USD,-DCMAKE_IGNORE_PATH=/usr/local/lib/cmake/TBB -DTBB_ROOT_DIR=${INSTALL_PREFIX} -DTBB_INCLUDE_DIR=${INSTALL_PREFIX}/include -DTBB_LIBRARY=${INSTALL_PREFIX}/lib/libtbb.so -DTBB_tbb_LIBRARY_RELEASE=${INSTALL_PREFIX}/lib/libtbb.so -DPython3_EXECUTABLE=${pixar_python} -DPYTHON_EXECUTABLE=${pixar_python}"
    "Blosc,-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "OpenVDB,-DTbb_tbb_LIBRARY_RELEASE=${INSTALL_PREFIX}/lib/libtbb.so -DTbb_tbb_LIBRARY_DEBUG=${INSTALL_PREFIX}/lib/libtbb.so"
    "${feature_args[@]}"
    "${INSTALL_PREFIX}"
  )
  printf '%q ' "${command[@]}" > "${evidence_root}/build-argv.txt"
  printf '\n' >> "${evidence_root}/build-argv.txt"
  "${command[@]}" 2>&1 | tee "${evidence_root}/build.log"

  if [[ -n "${PTEX_BUFFER_PATCH_SHA256:-}" ]]; then
    ptex_library="$(
      find "${INSTALL_PREFIX}" -type f -name 'libPtex.so*' -print \
        | LC_ALL=C sort | head -1
    )"
    [[ -n "${ptex_library}" ]]
    ptex_library_dir="$(dirname "${ptex_library}")"
    "${CXX}" -std=c++17 -O1 -g \
      -fsanitize=address,undefined -fno-omit-frame-pointer \
      -I "${INSTALL_PREFIX}/include" \
      "${ptex_validator}" \
      -L "${ptex_library_dir}" \
      -Wl,-rpath,"${ptex_library_dir}" \
      -lPtex \
      -o /opt/moana-debug/validate_ptex_file_asan
    ldd /opt/moana-debug/validate_ptex_file_asan \
      > "${evidence_root}/runtime/validate-ptex-file-ldd.txt"
    /opt/moana-debug/validate_ptex_file_asan --self-test \
      | tee "${evidence_root}/runtime/validate-ptex-file-self-test.txt"
  fi
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

runtime_python() {
  if [[ "${BUILD_PATH}" == pixar-build-usd ]]; then
    printf '%s\n' "${INSTALL_PREFIX}/bin/python3"
  else
    command -v python3
  fi
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
  selected_python="$(runtime_python)"
  "${selected_python}" - <<'PY' > "${evidence_root}/runtime/python-pxr.txt"
from pxr import Plug, Usd
import pxr
print("pxr_file=" + pxr.__file__)
print("usd_version=" + ".".join(str(part) for part in Usd.GetVersion()))
registry = Plug.Registry()
plugins = sorted(plugin.name for plugin in registry.GetAllPlugins())
print("plugin_count=" + str(len(plugins)))
print("plugin_names=" + ",".join(plugins))
PY
  {
    echo "executable=${selected_python}"
    "${selected_python}" -VV
  } > "${evidence_root}/runtime/python-version.txt"
  if [[ "${BUILD_PATH}" == pixar-build-usd ]]; then
    observed_python="$("${selected_python}" -c \
      'import platform; print(platform.python_version())')"
    [[ "${observed_python}" == "${PYTHON_VERSION}" ]]
  fi
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
      runtime/python-version.txt \
      runtime/python-pxr.txt \
      install-inventory.txt \
      > runtime/evidence-sha256.txt
  )
}

record_debug_runtime() {
  [[ "${debug_build}" == 1 ]] || return 0

  command -v gdb > "${evidence_root}/runtime/gdb-path.txt"
  gdb --configuration > "${evidence_root}/runtime/gdb-configuration.txt"

  hdst_library="$(find "${INSTALL_PREFIX}" -type f -name 'libusd_hdSt.so' -print -quit)"
  usd_module="$(find "${INSTALL_PREFIX}/lib/python" -type f -path '*/pxr/Usd/_usd.so' -print -quit)"
  [[ -n "${hdst_library}" && -n "${usd_module}" ]]

  : > "${evidence_root}/runtime/debug-sections.txt"
  : > "${evidence_root}/runtime/build-ids.txt"
  for binary in "${hdst_library}" "${usd_module}"; do
    {
      echo "=== ${binary}"
      readelf -SW "${binary}"
    } >> "${evidence_root}/runtime/debug-sections.txt"
    {
      echo "=== ${binary}"
      readelf -n "${binary}"
    } >> "${evidence_root}/runtime/build-ids.txt"
  done
  grep -Fq '.debug_info' "${evidence_root}/runtime/debug-sections.txt"
  grep -Fq '.debug_line' "${evidence_root}/runtime/debug-sections.txt"
  grep -Fq 'Build ID:' "${evidence_root}/runtime/build-ids.txt"

  gdb --quiet --batch \
    -ex 'set debuginfod enabled off' \
    -ex 'info sources' \
    -ex 'info functions HdStMaterial' \
    "${hdst_library}" \
    > "${evidence_root}/runtime/gdb-storm-symbols.txt" 2>&1
  grep -Fq 'pxr/imaging/hdSt/material.cpp' \
    "${evidence_root}/runtime/gdb-storm-symbols.txt"

  grep -R -E \
    'PXR_ENABLE_PTEX_SUPPORT:BOOL=ON' \
    "${evidence_root}/cmake-cache" \
    > "${evidence_root}/runtime/ptex-feature.txt"
  grep -R -E \
    'PXR_ENABLE_OPENVDB_SUPPORT:BOOL=ON' \
    "${evidence_root}/cmake-cache" \
    > "${evidence_root}/runtime/openvdb-feature.txt"
  find "${INSTALL_PREFIX}" -type f -name 'libPtex.so*' -print \
    > "${evidence_root}/runtime/ptex-libraries.txt"
  find "${INSTALL_PREFIX}" -type f -name 'libopenvdb.so*' -print \
    > "${evidence_root}/runtime/openvdb-libraries.txt"
  [[ -s "${evidence_root}/runtime/ptex-libraries.txt" ]]
  [[ -s "${evidence_root}/runtime/openvdb-libraries.txt" ]]
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

case "${BUILD_PATH}" in
  pixar-build-usd) build_pixar ;;
  aswf-docker-build-usd) build_aswf ;;
esac

configure_runtime
record_runtime
record_debug_runtime
printf '0\n' > "${status_file}"
trap - EXIT
