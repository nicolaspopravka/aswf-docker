#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="${repo_root}/scripts/vfx/build_usd.sh"
harness="${repo_root}/scripts/matrix/build_openusd_path_image.sh"
workflow="${repo_root}/.github/workflows/targeted-openusd-materialx-images.yml"
expected_helper_sha="1247e6fb475885c414687813b93afd2e83d49b89566905be801fe998bd767ab2"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[[ "$(hash_file "${helper}")" == "${expected_helper_sha}" ]]
bash -n "${harness}"
bash -n "$0"
if grep -Fq -- '--retry-all-errors' "${harness}"; then
  echo "The stock ci-usd curl is too old for --retry-all-errors." >&2
  exit 1
fi
grep -Fq 'plugin_names=' "${harness}"
grep -Fq "grep -R -l -F '\"HdStormRendererPlugin\"'" "${harness}"
grep -Fq "MaterialXCore/Generated.h" "${harness}"
grep -Fq "cd \"\${evidence_root}\"" "${harness}"
if grep -Fq 'HdStormRendererPlugin=True' "${harness}"; then
  echo "Plug package names must not be confused with renderer type names." >&2
  exit 1
fi

[[ "$(grep -c 'name: .*cy20' "${workflow}")" == 10 ]]
grep -Fq 'ghcr.io/${{ github.repository_owner }}/openusd-build-paths' "${workflow}"
grep -Fq 'permissions:' "${workflow}"
grep -Fq 'packages: write' "${workflow}"
grep -Fq 'scope:' "${workflow}"
grep -Fq '|| [[ "$SCOPE" == "$NAME" ]]' "${workflow}"
grep -Fq '|| [[ "$SCOPE" == pixar && "$NAME" == pixar-* ]]' "${workflow}"
[[ "$(grep -c 'base: aswf/ci-common:.*@sha256:' "${workflow}")" == 5 ]]
[[ "$(grep -c 'base: aswf/ci-usd:.*@sha256:' "${workflow}")" == 5 ]]
[[ "$(grep -c 'install_prefix: /usr/local' "${workflow}")" == 10 ]]
[[ "$(grep -c 'python: "' "${workflow}")" == 5 ]]
[[ "$(grep -c 'python_sha256: [0-9a-f]' "${workflow}")" == 5 ]]
if grep -Fq 'install_prefix: /opt/openusd' "${workflow}"; then
  echo "All build paths must share the /usr/local runtime layout." >&2
  exit 1
fi
grep -Fq 'absent ASWF_OPENUSD_VERSION: Pixar base is not ci-usd' "${harness}"
grep -Fq 'https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz' "${harness}"
grep -Fq '"${pixar_python}" "${pixar_script}"' "${harness}"
grep -Fq 'observed_python' "${harness}"

common=(
  CY=2025
  OPENUSD_VERSION=25.05.01
  PYTHON_VERSION=3.11.15
  PYTHON_SHA256=f4de1b10bd6c70cbb9fa1cd71fc5038b832747a74ee59d599c69ce4846defb50
  SOURCE_REVISION=1595c62ea8381b5b22eb8621afc8652f89b6136d
  SOURCE_SHA256=f424e8db26e063a1b005423ee52142e75c38185bbd4b8126ef64173e906dd50f
  EXPECTED_GCC_MAJOR=11
  BUILD_JOBS=4
  ASWF_SOURCE_COMMIT=2c8484137a2f056a0abfd504dd5ad166240ab47e
  WORKFLOW_REVISION=local-dry-run
)

env "${common[@]}" \
  BUILD_PATH=pixar-build-usd \
  MATERIALX_VERSION=1.39.3 \
  SCRIPT_SHA256=b53a004a6536e24fad54de9fc263b6e2090aefbb23061a638d84c749160b4068 \
  INSTALL_PREFIX=/usr/local \
  "${harness}" dry-run >/dev/null

env "${common[@]}" \
  BUILD_PATH=aswf-docker-build-usd \
  PYTHON_VERSION= \
  PYTHON_SHA256= \
  MATERIALX_VERSION=1.39.3 \
  SCRIPT_SHA256="${expected_helper_sha}" \
  INSTALL_PREFIX=/usr/local \
  "${harness}" dry-run >/dev/null

echo "OpenUSD build-path image inputs are valid."
