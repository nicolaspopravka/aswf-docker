#!/usr/bin/env bash
set -euo pipefail

# Build only the corrected MaterialX/OpenUSD packages inside a stock VFX-all
# image. The caller mounts this checkout at /src and an output directory at
# /out; /out/root is suitable as the build context for a derived image.

year="${ASWF_VFXPLATFORM_VERSION:?missing ASWF_VFXPLATFORM_VERSION}"
usd_version="${ASWF_OPENUSD_VERSION:?missing ASWF_OPENUSD_VERSION}"
materialx_version="${ASWF_MATERIALX_VERSION:?missing ASWF_MATERIALX_VERSION}"
jobs="${ASWF_BUILD_JOBS:-$(nproc)}"

export ASWF_PKG_ORG=diagnostic
export CMAKE_BUILD_PARALLEL_LEVEL="${jobs}"
export CONAN_HOME=/out/conan-home
profile="${CONAN_HOME}/profiles/targeted-vfx${year}"
recipe_root=/out/recipes
deploy_root=/out/deploy

rm -rf "${CONAN_HOME}" "${recipe_root}" "${deploy_root}" /out/root
mkdir -p "${CONAN_HOME}" "${recipe_root}" /out/root/usr/local
cp -a /src/packages/conan/settings/. "${CONAN_HOME}/"
cp -a /src/packages/conan/recipes/materialx "${recipe_root}/materialx"
cp -a /src/packages/conan/recipes/openusd "${recipe_root}/openusd"

profile="${CONAN_HOME}/profiles/targeted-vfx${year}"
sed -i -E \
  "s#^materialx/\\*:.*\$#materialx/*: materialx/${materialx_version}@diagnostic/vfx${year}#" \
  "${profile}"
sed -i -E \
  "s#^openusd/\\*:.*\$#openusd/*: openusd/${usd_version}@diagnostic/vfx${year}#" \
  "${profile}"

# Keep the recipe dependency and the profile override in agreement for the
# CY2026 Pixar-pin variant as well as the stock years.
sed -i -E \
  "s#materialx_version = .* if Version\\(self.version\\) == \"24\\.08\" else .*#materialx_version = \"${materialx_version}\"#" \
  "${recipe_root}/openusd/conanfile.py"

conan create "${recipe_root}/materialx" \
  --version="${materialx_version}" \
  --user=diagnostic --channel="vfx${year}" \
  --profile:all="${profile}" \
  --build='materialx/*'

conan create "${recipe_root}/openusd" \
  --version="${usd_version}" \
  --user=diagnostic --channel="vfx${year}" \
  --profile:all="${profile}" \
  --build='openusd/*'

conan install \
  --requires="openusd/${usd_version}@diagnostic/vfx${year}" \
  --profile:all="${profile}" \
  --deployer-folder="${deploy_root}" \
  --deployer=full_deploy \
  --build=never

usd_dir="$(find "${deploy_root}/host/openusd" -type d -name x86_64 -print -quit)"
mtlx_dir="$(find "${deploy_root}/host/materialx" -type d -name x86_64 -print -quit)"
[[ -n "${usd_dir}" && -d "${usd_dir}" ]] || { echo "OpenUSD deploy missing" >&2; exit 1; }
[[ -n "${mtlx_dir}" && -d "${mtlx_dir}" ]] || { echo "MaterialX deploy missing" >&2; exit 1; }
cp -a "${usd_dir}/." /out/root/usr/local/
cp -a "${mtlx_dir}/." /out/root/usr/local/

{
  echo "vfxplatform=${year}"
  echo "openusd=${usd_version}"
  echo "materialx=${materialx_version}"
  echo "jobs=${jobs}"
  conan --version
} > /out/targeted-build-provenance.txt

rm -rf "${CONAN_HOME}" "${recipe_root}" "${deploy_root}"
