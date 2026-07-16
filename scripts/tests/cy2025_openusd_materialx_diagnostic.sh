#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

mode="${1:-dry-run}"
variant="${DIAGNOSTIC_VARIANT:-pixar-parity}"
root="${DIAGNOSTIC_ROOT:-${PWD}/diagnostic-artifacts}"
image="${DIAGNOSTIC_IMAGE:-aswf/ci-vfxall:2025}"
jobs="${DIAGNOSTIC_JOBS:-4}"

case "${variant}" in pixar-parity|stock-options) ;; *) echo "unknown variant: ${variant}" >&2; exit 2;; esac
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
  echo "mem_kib=${mem_kib} free_kib=${free_kib}"
  (( mem_kib >= 14 * 1024 * 1024 )) || { echo "capacity gate: less than 14 GiB RAM" >&2; exit 3; }
  (( free_kib >= 50 * 1024 * 1024 )) || { echo "capacity gate: less than 50 GiB free disk" >&2; exit 3; }
}

run_container() {
  docker pull "${image}"
  docker image inspect "${image}" > "${root}/metadata/base-image.json"
  docker run --rm \
    -e DIAGNOSTIC_INNER=1 -e DIAGNOSTIC_VARIANT="${variant}" \
    -e DIAGNOSTIC_JOBS="${jobs}" -e DIAGNOSTIC_ROOT=/evidence \
    -v "${PWD}:/src:ro" -v "${root}:/evidence" -w /src \
    "${image}" scripts/tests/cy2025_openusd_materialx_diagnostic.sh inner
}

inner() {
  export ASWF_PKG_ORG=aswf
  export CMAKE_BUILD_PARALLEL_LEVEL="${jobs}"
  export CONAN_HOME="${root}/conan-home"
  rm -rf "${CONAN_HOME}"
  cp -a /src/packages/conan/settings "${CONAN_HOME}"
  rm -rf "${root}/recipes"
  mkdir -p "${root}/recipes"
  cp -a /src/packages/conan/recipes/materialx "${root}/recipes/materialx"
  cp -a /src/packages/conan/recipes/openusd "${root}/recipes/openusd"
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
  cp "${profile}" "${root}/metadata/vfx2025-diagnostic.profile"
  env | sort > "${root}/metadata/environment.txt"
  git -c safe.directory=/src -C /src rev-parse HEAD > "${root}/metadata/aswf-docker-commit.txt"
  git -c safe.directory=/src -C /src status --short > "${root}/metadata/aswf-docker-status.txt"
  conan --version > "${root}/metadata/conan-version.txt"
  conan create "${root}/recipes/materialx" --version=1.39.3 \
    --user=diagnostic --channel=vfx2025 --profile:all="${profile}" \
    -o 'materialx/*:with_openimageio=False' --build='materialx/*' \
    2>&1 | tee "${root}/build-logs/materialx.log"
  usd_option_names=(
    'shared=True' 'with_gpu=True' 'with_gl=True' 'with_python=True'
    'with_materialx=True' 'with_usdview=False'
  )
  if [[ "${variant}" == pixar-parity ]]; then
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
  conan create "${root}/recipes/openusd" --version=25.05.01 \
    --user=diagnostic --channel=vfx2025 --profile:all="${profile}" \
    "${usd_dependency_options[@]}" "${usd_consumer_options[@]}" \
    --build='openusd/*' \
    2>&1 | tee "${root}/build-logs/openusd.log"
  conan install --requires="${usd_ref}" --profile:all="${profile}" \
    "${usd_dependency_options[@]}" --output-folder="${root}/results/generated" \
    --deployer-folder="${root}/results/deployed" --deployer=full_deploy \
    --generator=VirtualRunEnv --format=json > "${root}/results/graph.json"
  set +u
  source "${root}/results/generated/conanrun.sh"
  set -u
  /src/scripts/tests/openusd_materialx_render_smoke.sh "${root}/results/smoke"
  rm -rf "${root}/conan-home" "${root}/recipes" \
    "${root}/results/deployed" "${root}/results/generated"
}

case "${mode}" in
  capacity) capacity ;;
  run) run_container ;;
  inner) inner ;;
  dry-run) echo "variant=${variant} image=${image} jobs=${jobs}"; echo "would build ${mtlx_ref:-materialx/1.39.3} then openusd/25.05.01" ;;
  *) echo "usage: $0 {capacity|run|inner|dry-run}" >&2; exit 2 ;;
esac
