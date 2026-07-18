#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

mode="${1:-dry-run}"
variant="${DIAGNOSTIC_VARIANT:-pixar-parity}"
root="${DIAGNOSTIC_ROOT:-${PWD}/diagnostic-artifacts}"
image="${DIAGNOSTIC_IMAGE:-aswf/ci-vfxall:2025}"
jobs="${DIAGNOSTIC_JOBS:-4}"

case "${variant}" in pixar-parity|pixar-materialx|pixar-materialx-layout|pixar-core-tbb|pixar-build-usd|pixar-build-usd-ci-common5|stock-options) ;; *) echo "unknown variant: ${variant}" >&2; exit 2;; esac
if [[ "${variant}" == pixar-build-usd-ci-common5 ]]; then
  image="aswf/ci-common:5-clang19"
fi
mkdir -p "${root}"/{build-logs,metadata,results}

capacity() {
  uname -a
  nproc
  free -h
  df -h /
  docker info || true
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
    /usr/local/share/powershell /usr/share/swift /usr/local/.ghcup \
    /usr/local/aws-cli /usr/local/aws-sam-cli /usr/local/julia* /usr/lib/jvm || true
  sudo apt-get clean
  docker system prune -af || true
  mem_kib="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  free_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  min_free_gib=50
  capacity_mode=full-build
  if [[ -n "${DIAGNOSTIC_REUSE_RUN_ID:-}" ]]; then
    min_free_gib=20
    capacity_mode=artifact-reuse
  fi
  echo "mem_kib=${mem_kib} free_kib=${free_kib} capacity_mode=${capacity_mode} min_free_gib=${min_free_gib}"
  (( mem_kib >= 14 * 1024 * 1024 )) || { echo "capacity gate: less than 14 GiB RAM" >&2; exit 3; }
  (( free_kib >= min_free_gib * 1024 * 1024 )) || {
    echo "capacity gate: less than ${min_free_gib} GiB free disk for ${capacity_mode}" >&2
    exit 3
  }
}

install_software_gl() {
  mkdir -p "${root}/metadata"
  gl_packages=(mesa-dri-drivers)
  gl_rpms=(mesa-dri-drivers mesa-libGL mesa-libEGL)
  if [[ "${variant}" == pixar-build-usd-ci-common5 ]]; then
    gl_packages+=(xorg-x11-server-Xvfb glx-utils)
    gl_rpms+=(xorg-x11-server-Xvfb glx-utils)
  fi
  dnf -y install "${gl_packages[@]}" \
    > "${root}/metadata/mesa-dri-install.log" 2>&1
  rpm -q "${gl_rpms[@]}" \
    > "${root}/metadata/mesa-packages.txt"
}

prepare_ci_common5_runtime() {
  gcc_toolset_root="/opt/rh/${ASWF_DTS_PREFIX:?missing ASWF_DTS_PREFIX}-${ASWF_DTS_VERSION:?missing ASWF_DTS_VERSION}/root"
  [[ -x "${gcc_toolset_root}/usr/bin/gcc" ]] || {
    echo "Image-declared GCC toolset is missing from ci-common: ${gcc_toolset_root}" >&2
    return 1
  }
  export PATH="${gcc_toolset_root}/usr/bin:${PATH}"
  export LD_LIBRARY_PATH="${gcc_toolset_root}/usr/lib64:${gcc_toolset_root}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export CC=gcc CXX=g++
  python3 -m pip install --disable-pip-version-check --no-cache-dir \
    --report "${root}/metadata/pyside-pip-report.json" 'PySide6==6.8.3' \
    > "${root}/metadata/pyside-pip-install.log" 2>&1
  {
    echo "image=${image}"
    echo "gcc_toolset_root=${gcc_toolset_root}"
    python3 -c 'import sys; print(sys.executable, sys.version)'
    python3 -c 'import PySide6; print(PySide6.__file__, PySide6.__version__)'
  } > "${root}/metadata/ci-common5-runtime.txt"
}

run_container() {
  docker pull "${image}"
  docker image inspect "${image}" > "${root}/metadata/base-image.json"
  docker run --rm \
    -e DIAGNOSTIC_INNER=1 -e DIAGNOSTIC_VARIANT="${variant}" \
    -e DIAGNOSTIC_JOBS="${jobs}" -e DIAGNOSTIC_ROOT=/evidence \
    -e DIAGNOSTIC_RENDER_CONTEXT="${DIAGNOSTIC_RENDER_CONTEXT:-stock-xvfb}" \
    -v "${PWD}:/src:ro" -v "${root}:/evidence" -w /src \
    "${image}" scripts/tests/cy2025_openusd_materialx_diagnostic.sh inner
}

reuse_container() {
  docker pull "${image}"
  docker image inspect "${image}" > "${root}/metadata/base-image.json"
  docker run --rm \
    -e DIAGNOSTIC_INNER=1 -e DIAGNOSTIC_VARIANT="${variant}" \
    -e DIAGNOSTIC_REUSE_RUN_ID="${DIAGNOSTIC_REUSE_RUN_ID:-}" \
    -e DIAGNOSTIC_ROOT=/evidence \
    -e DIAGNOSTIC_RENDER_CONTEXT="${DIAGNOSTIC_RENDER_CONTEXT:-stock-xvfb}" \
    -e DIAGNOSTIC_MTLX_STDLIB_PATH_MODE="${DIAGNOSTIC_MTLX_STDLIB_PATH_MODE:-parent}" \
    -v "${PWD}:/src:ro" -v "${root}:/evidence" -w /src \
    "${image}" scripts/tests/cy2025_openusd_materialx_diagnostic.sh inner-reuse
}

run_reuse_smoke() {
  local mode="$1"
  local mtlx_root="$2"
  local stdlib_path
  case "${mode}" in
    parent) stdlib_path="${mtlx_root}/share/MaterialX" ;;
    libraries) stdlib_path="${mtlx_root}/share/MaterialX/libraries" ;;
    *) echo "unknown MaterialX stdlib path mode: ${mode}" >&2; return 2 ;;
  esac
  [[ -d "${stdlib_path}" ]] || {
    echo "MaterialX stdlib path is missing: ${stdlib_path}" >&2
    return 1
  }
  export PXR_MTLX_STDLIB_SEARCH_PATHS="${stdlib_path}"
  printf '%s\n' "${stdlib_path}" > "${root}/metadata/materialx-stdlib-path-${mode}.txt"
  rm -rf "${root}/results/smoke-${mode}"
  set +e
  /src/scripts/tests/openusd_materialx_render_smoke.sh "${root}/results/smoke-${mode}"
  local smoke_status=$?
  set -e
  return "${smoke_status}"
}

run_reuse_smoke_modes() {
  local mtlx_root="$1"
  local mode
  local result=0
  case "${DIAGNOSTIC_MTLX_STDLIB_PATH_MODE:-parent}" in
    parent) modes=(parent) ;;
    libraries) modes=(libraries) ;;
    both) modes=(parent libraries) ;;
    *) echo "unknown MaterialX stdlib path mode: ${DIAGNOSTIC_MTLX_STDLIB_PATH_MODE}" >&2; return 2 ;;
  esac
  for mode in "${modes[@]}"; do
    run_reuse_smoke "${mode}" "${mtlx_root}" || result=1
  done
  return "${result}"
}

inner_reuse() {
  if [[ "${variant}" == pixar-build-usd || "${variant}" == pixar-build-usd-ci-common5 ]]; then
    if [[ "${variant}" == pixar-build-usd-ci-common5 ]]; then
      prepare_ci_common5_runtime
    fi
    install_root="${root}/results/pixar-install"
    [[ -f "${install_root}/bin/usdrecord" ]] || {
      echo "reused Pixar installation is missing usdrecord: ${install_root}/bin/usdrecord" >&2
      return 1
    }
    [[ -d "${install_root}/lib/python/pxr" ]] || {
      echo "reused Pixar installation is missing pxr modules" >&2
      return 1
    }
    chmod +x "${install_root}/bin/usdrecord"
    export PATH="${install_root}/bin:${PATH}"
    export LD_LIBRARY_PATH="${install_root}/lib:${LD_LIBRARY_PATH:-}"
    export PYTHONPATH="${install_root}/lib/python"
    mtlx_library="$(find "${install_root}" -type d -path '*/libraries' -print -quit)"
    [[ -n "${mtlx_library}" ]] || {
      echo "reused Pixar installation is missing MaterialX libraries" >&2
      return 1
    }
    export PXR_MTLX_STDLIB_SEARCH_PATHS="$(dirname "${mtlx_library}")"
    export DIAGNOSTIC_REQUIRE_MATERIALX_PYTHON=0
    if [[ "${variant}" == pixar-build-usd-ci-common5 ]]; then
      export DIAGNOSTIC_USDRECORD_PYTHON="$(command -v python3)"
    fi
    printf '%s\n' "${DIAGNOSTIC_REUSE_RUN_ID:-unknown}" \
      > "${root}/metadata/reused-run-id.txt"
    asset_root="${root}/input-assets"
    rm -rf "${asset_root}"
    git init "${asset_root}"
    git -C "${asset_root}" remote add origin https://github.com/usd-wg/assets.git
    git -C "${asset_root}" -c protocol.version=2 fetch --depth=1 \
      --filter=blob:none origin 907d5f17bbe933fc14441a3f3ab69a5bd8abe32a
    git -C "${asset_root}" sparse-checkout init --cone
    git -C "${asset_root}" sparse-checkout set full_assets/OpenChessSet
    git -C "${asset_root}" checkout --detach FETCH_HEAD
    git -C "${asset_root}" rev-parse HEAD \
      > "${root}/metadata/openchessset-commit.txt"
    export DIAGNOSTIC_OPENCHESSSET="${asset_root}/full_assets/OpenChessSet/chess_set.usda"
    rm -rf "${root}/results/smoke"
    install_software_gl
    set +e
    /src/scripts/tests/openusd_materialx_render_smoke.sh "${root}/results/smoke"
    smoke_status=$?
    set -e
    rm -rf "${asset_root}"
    return "${smoke_status}"
  fi
  deploy_root="${root}/results/deployed/full_deploy/host"
  usd_root="${deploy_root}/openusd/25.05.01/Release/x86_64"
  mtlx_root="${deploy_root}/materialx/1.39.3/Release/x86_64"
  [[ -x "${usd_root}/bin/usdrecord" || -f "${usd_root}/bin/usdrecord" ]] || {
    echo "reused deployment is missing usdrecord: ${usd_root}/bin/usdrecord" >&2
    return 1
  }
  [[ -d "${usd_root}/lib/python/pxr" ]] || {
    echo "reused deployment is missing pxr modules" >&2
    return 1
  }
  [[ -d "${mtlx_root}/share/MaterialX/python/MaterialX" ]] || {
    echo "reused deployment is missing MaterialX modules" >&2
    return 1
  }
  chmod +x "${usd_root}/bin/usdrecord"
  path_entries="$(find "${deploy_root}" -type d -name bin -print | paste -sd: -)"
  lib_entries="$(find "${deploy_root}" -type d -name lib -print | paste -sd: -)"
  export PATH="${path_entries}:${PATH}"
  export LD_LIBRARY_PATH="${lib_entries}:${LD_LIBRARY_PATH:-}"
  export PYTHONPATH="${usd_root}/lib/python:${mtlx_root}/share/MaterialX/python"
  printf '%s\n' "${DIAGNOSTIC_REUSE_RUN_ID:-unknown}" \
    > "${root}/metadata/reused-run-id.txt"
  install_software_gl
  set +e
  run_reuse_smoke_modes "${mtlx_root}"
  smoke_status=$?
  set -e
  rm -rf "${root}/results/deployed" "${root}/results/generated"
  return "${smoke_status}"
}

inner_pixar_build_usd() {
  source_url=https://github.com/PixarAnimationStudios/OpenUSD/archive/refs/tags/v25.05.01.tar.gz
  source_sha=f424e8db26e063a1b005423ee52142e75c38185bbd4b8126ef64173e906dd50f
  source_archive="${root}/openusd-v25.05.01.tar.gz"
  source_root="${root}/openusd-source"
  install_root="${root}/results/pixar-install"
  rm -rf "${source_root}" "${install_root}"
  if [[ "${variant}" == pixar-build-usd-ci-common5 ]]; then
    prepare_ci_common5_runtime
  fi
  curl -L --fail --retry 3 -o "${source_archive}" "${source_url}"
  echo "${source_sha}  ${source_archive}" | sha256sum --check \
    > "${root}/metadata/openusd-source-sha256.txt"
  mkdir -p "${source_root}"
  tar -xzf "${source_archive}" --strip-components=1 -C "${source_root}"
  {
    echo "source_url=${source_url}"
    echo "source_sha256=${source_sha}"
    echo "variant=${variant}"
    echo "image=${image}"
    gcc --version | head -1
    g++ --version | head -1
    cmake --version | head -1
    python3 --version
  } > "${root}/metadata/pixar-build-usd-inputs.txt"
  python3 "${source_root}/build_scripts/build_usd.py" \
    -j "${jobs}" \
    --no-embree --no-prman \
    --no-usdview --no-examples --no-tutorials \
    --no-tests --no-docs --no-python-docs \
    --build-args "USD,-DCMAKE_IGNORE_PATH=/usr/local/lib/cmake/TBB -DTBB_ROOT_DIR=${install_root} -DTBB_INCLUDE_DIR=${install_root}/include -DTBB_LIBRARY=${install_root}/lib/libtbb.so -DTBB_tbb_LIBRARY_RELEASE=${install_root}/lib/libtbb.so" \
    --materialx "${install_root}" \
    2>&1 | tee "${root}/build-logs/pixar-build-usd.log"
  : > "${root}/metadata/pixar-cmake-tbb-cache.txt"
  while IFS= read -r cache; do
    echo "=== ${cache}" >> "${root}/metadata/pixar-cmake-tbb-cache.txt"
    grep -E '^(CMAKE_IGNORE_PATH|TBB[^:]*)[:=]' "${cache}" \
      >> "${root}/metadata/pixar-cmake-tbb-cache.txt" || true
  done < <(find "${install_root}/build" -name CMakeCache.txt -type f -print)
  rm -rf "${source_root}" "${source_archive}"
  rm -rf "${install_root}/build" "${install_root}/src"
  readelf -d "${install_root}/lib/libusd_hd.so" \
    > "${root}/metadata/pixar-usd-hd-dynamic.txt"
  grep -Eq 'Shared library: \[libtbb\.so\.2\]' \
    "${root}/metadata/pixar-usd-hd-dynamic.txt" || {
      echo "Pixar control did not link libusd_hd to classic TBB" >&2
      return 1
    }
  export PATH="${install_root}/bin:${PATH}"
  export LD_LIBRARY_PATH="${install_root}/lib:${LD_LIBRARY_PATH:-}"
  export PYTHONPATH="${install_root}/lib/python"
  mtlx_library="$(find "${install_root}" -type d -path '*/libraries' -print -quit)"
  [[ -n "${mtlx_library}" ]] || {
    echo "Pixar control install is missing MaterialX libraries" >&2
    return 1
  }
  export PXR_MTLX_STDLIB_SEARCH_PATHS="$(dirname "${mtlx_library}")"
  export DIAGNOSTIC_REQUIRE_MATERIALX_PYTHON=0
  if [[ "${variant}" == pixar-build-usd-ci-common5 ]]; then
    export DIAGNOSTIC_USDRECORD_PYTHON="$(command -v python3)"
  fi
  install_software_gl
  /src/scripts/tests/openusd_materialx_render_smoke.sh "${root}/results/smoke"
}

inner() {
  if [[ "${variant}" == pixar-build-usd || "${variant}" == pixar-build-usd-ci-common5 ]]; then
    inner_pixar_build_usd
    return
  fi
  export ASWF_PKG_ORG=aswf
  export CMAKE_BUILD_PARALLEL_LEVEL="${jobs}"
  export CONAN_HOME="${root}/conan-home"
  rm -rf "${CONAN_HOME}"
  cp -a /src/packages/conan/settings "${CONAN_HOME}"
  rm -rf "${root}/recipes"
  mkdir -p "${root}/recipes"
  cp -a /src/packages/conan/recipes/materialx "${root}/recipes/materialx"
  cp -a /src/packages/conan/recipes/openusd "${root}/recipes/openusd"
  if [[ "${variant}" == pixar-core-tbb ]]; then
    cp -a /src/packages/conan/recipes/onetbb/2020.x "${root}/recipes/onetbb"
  fi
  if [[ "${variant}" == pixar-materialx || "${variant}" == pixar-materialx-layout || "${variant}" == pixar-core-tbb ]]; then
    export DIAGNOSTIC_SKIP_MATERIALX_PYTHON_TEST=1
    sed -i -E \
      's#tc\.variables\["MATERIALX_BUILD_PYTHON"\][[:space:]]*=[[:space:]]*"ON"#tc.variables["MATERIALX_BUILD_PYTHON"] = "OFF"#' \
      "${root}/recipes/materialx/conanfile.py"
    grep -F 'tc.variables["MATERIALX_BUILD_PYTHON"] = "OFF"' \
      "${root}/recipes/materialx/conanfile.py" \
      > "${root}/metadata/materialx-pixar-build-options.txt" || {
        echo "MaterialX Pixar build option remained enabled" >&2
        return 1
      }
  fi
  if [[ "${variant}" == pixar-materialx-layout || "${variant}" == pixar-core-tbb ]]; then
    sed -i -E \
      's#tc\.variables\["MATERIALX_INSTALL_STDLIB_PATH"\].*#tc.variables["MATERIALX_INSTALL_STDLIB_PATH"] = "libraries"#' \
      "${root}/recipes/materialx/conanfile.py"
    sed -i -E \
      's#tc\.variables\["MATERIALX_INSTALL_RESOURCES_PATH"\].*#tc.variables["MATERIALX_INSTALL_RESOURCES_PATH"] = "resources"#' \
      "${root}/recipes/materialx/conanfile.py"
    sed -i -E \
      's#os\.path\.join\(self\.package_folder, "share", "MaterialX"\)#self.package_folder#' \
      "${root}/recipes/materialx/conanfile.py"
    sed -i -E \
      '/tc\.variables\["MATERIALX_STDLIB_DIR"\]/d' \
      "${root}/recipes/openusd/conanfile.py"
    {
      grep -F 'tc.variables["MATERIALX_INSTALL_STDLIB_PATH"] = "libraries"' \
        "${root}/recipes/materialx/conanfile.py"
      grep -F 'tc.variables["MATERIALX_INSTALL_RESOURCES_PATH"] = "resources"' \
        "${root}/recipes/materialx/conanfile.py"
      grep -A2 '"PXR_MTLX_STDLIB_SEARCH_PATHS"' \
        "${root}/recipes/materialx/conanfile.py"
      if grep -Fq 'tc.variables["MATERIALX_STDLIB_DIR"]' \
        "${root}/recipes/openusd/conanfile.py"; then
        echo "OpenUSD retained the explicit MaterialX stdlib hint" >&2
        return 1
      fi
    } > "${root}/metadata/materialx-pixar-layout-options.txt"
  fi
  profile="${CONAN_HOME}/profiles/vfx2025-diagnostic"
  mtlx_ref=materialx/1.39.3@diagnostic/vfx2025
  usd_ref=openusd/25.05.01@diagnostic/vfx2025
  cp "${CONAN_HOME}/profiles/vfx2025" "${profile}"
  sed -i -E \
    's#^materialx/\*:.*$#materialx/*: materialx/1.39.3@diagnostic/vfx2025#' \
    "${profile}"
  sed -i -E \
    's#^openusd/\*:.*$#openusd/*: openusd/25.05.01@diagnostic/vfx2025#' \
    "${profile}"
  if [[ "${variant}" == pixar-core-tbb ]]; then
    sed -i -E \
      's#^onetbb/\*:.*$#onetbb/*: onetbb/2020.3.1@diagnostic/vfx2025#' \
      "${profile}"
    grep -F 'onetbb/*: onetbb/2020.3.1@diagnostic/vfx2025' "${profile}" \
      > "${root}/metadata/pixar-tbb-reference.txt"
  fi
  cp "${profile}" "${root}/metadata/vfx2025-diagnostic.profile"
  env | sort > "${root}/metadata/environment.txt"
  git -c safe.directory=/src -C /src rev-parse HEAD > "${root}/metadata/aswf-docker-commit.txt"
  git -c safe.directory=/src -C /src status --short > "${root}/metadata/aswf-docker-status.txt"
  conan --version > "${root}/metadata/conan-version.txt"
  if [[ "${variant}" == pixar-core-tbb ]]; then
    conan create "${root}/recipes/onetbb" --version=2020.3.1 \
      --user=diagnostic --channel=vfx2025 --profile:all="${profile}" \
      --build='onetbb/*' 2>&1 | tee "${root}/build-logs/onetbb.log"
  fi
  conan create "${root}/recipes/materialx" --version=1.39.3 \
    --user=diagnostic --channel=vfx2025 --profile:all="${profile}" \
    -o 'materialx/*:with_openimageio=False' --build='materialx/*' \
    2>&1 | tee "${root}/build-logs/materialx.log"
  usd_option_names=(
    'shared=True' 'with_gpu=True' 'with_gl=True' 'with_python=True'
    'with_materialx=True' 'with_usdview=False'
  )
  if [[ "${variant}" == pixar-parity || "${variant}" == pixar-materialx || "${variant}" == pixar-materialx-layout || "${variant}" == pixar-core-tbb ]]; then
    usd_option_names+=(
      'with_alembic=False' 'with_hdf5=False' 'with_opencolorio=False'
      'with_openimageio=False' 'with_openvdb=False' 'with_osl=False'
      'with_ptex=False'
    )
    for option in with_alembic with_hdf5 with_opencolorio with_openimageio \
      with_openvdb with_osl with_ptex with_usdview; do
      sed -i -E \
        "/default_options = \\{/,/^    \\}/ s#(\"${option}\"[[:space:]]*:[[:space:]]*)True#\1False#" \
        "${root}/recipes/openusd/conanfile.py"
    done
    sed -n '/default_options = {/,/^    }/p' \
      "${root}/recipes/openusd/conanfile.py" \
      > "${root}/metadata/openusd-parity-default-options.txt"
    for option in with_alembic with_hdf5 with_opencolorio with_openimageio \
      with_openvdb with_osl with_ptex with_usdview; do
      if grep -Eq "\"${option}\"[[:space:]]*:[[:space:]]*True" \
        "${root}/metadata/openusd-parity-default-options.txt"; then
        echo "OpenUSD parity default remained enabled: ${option}" >&2
        return 1
      fi
    done
  fi
  usd_dependency_options=()
  usd_consumer_options=()
  for option in "${usd_option_names[@]}"; do
    usd_dependency_options+=(-o "openusd/*:${option}")
    usd_consumer_options+=(-o "&:${option}")
  done
  usd_dependency_options+=(-o 'materialx/*:with_openimageio=False')
  usd_build_patterns=(--build='openusd/*')
  if [[ "${variant}" == pixar-core-tbb ]]; then
    # The TBB substitution changes OpenSubdiv's package ID, so the stock
    # remote binary cannot satisfy this diagnostic graph.
    usd_build_patterns+=(--build='opensubdiv/*')
  fi
  conan create "${root}/recipes/openusd" --version=25.05.01 \
    --user=diagnostic --channel=vfx2025 --profile:all="${profile}" \
    "${usd_dependency_options[@]}" "${usd_consumer_options[@]}" \
    "${usd_build_patterns[@]}" \
    2>&1 | tee "${root}/build-logs/openusd.log"
  conan install --requires="${usd_ref}" --profile:all="${profile}" \
    "${usd_dependency_options[@]}" --output-folder="${root}/results/generated" \
    --deployer-folder="${root}/results/deployed" --deployer=full_deploy \
    --generator=VirtualRunEnv --format=json > "${root}/results/graph.json"
  set +u
  source "${root}/results/generated/conanrun.sh"
  set -u
  if [[ "${variant}" == pixar-materialx || "${variant}" == pixar-materialx-layout || "${variant}" == pixar-core-tbb ]]; then
    export DIAGNOSTIC_REQUIRE_MATERIALX_PYTHON=0
  fi
  install_software_gl
  /src/scripts/tests/openusd_materialx_render_smoke.sh "${root}/results/smoke"
  rm -rf "${root}/conan-home" "${root}/recipes" \
    "${root}/results/deployed" "${root}/results/generated"
}

case "${mode}" in
  capacity) capacity ;;
  run) run_container ;;
  reuse) reuse_container ;;
  inner) inner ;;
  inner-reuse) inner_reuse ;;
  dry-run) echo "variant=${variant} image=${image} jobs=${jobs}"; echo "would build ${mtlx_ref:-materialx/1.39.3} then openusd/25.05.01" ;;
  *) echo "usage: $0 {capacity|run|reuse|inner|inner-reuse|dry-run}" >&2; exit 2 ;;
esac
