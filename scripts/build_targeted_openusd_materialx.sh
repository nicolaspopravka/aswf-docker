#!/usr/bin/env bash
set -euo pipefail

# Build only the corrected MaterialX/OpenUSD packages inside a stock VFX-all
# image. The caller mounts this checkout at /src and an output directory at
# /out; /out/root is suitable as the build context for a derived image.

year="${ASWF_VFXPLATFORM_VERSION:?missing ASWF_VFXPLATFORM_VERSION}"
usd_version="${ASWF_OPENUSD_VERSION:?missing ASWF_OPENUSD_VERSION}"
materialx_version="${ASWF_MATERIALX_VERSION:?missing ASWF_MATERIALX_VERSION}"
oiio_version="${ASWF_OPENIMAGEIO_VERSION:-}"
osl_version="${ASWF_OSL_VERSION:-}"
case "${year}" in
  2024)
    oiio_version="${oiio_version:-2.5.19.1}"
    osl_version="${osl_version:-1.13.11.0}"
    ;;
  2025)
    oiio_version="${oiio_version:-3.1.6.2}"
    osl_version="${osl_version:-1.14.11.0}"
    ;;
  2026)
    oiio_version="${oiio_version:-3.1.14.1}"
    osl_version="${osl_version:-1.15.5.0}"
    ;;
esac
jobs="${ASWF_BUILD_JOBS:-$(nproc)}"
case "${year}" in
  20[0-9][0-9]) ci_common_version="${year: -1}" ;;
  *) echo "Unsupported VFX Platform year: ${year}" >&2; exit 1 ;;
esac

# Stock ci-vfxall profiles resolve their prebuilt dependency graph from the
# ASWF Conan namespace. The two rebuilt recipes themselves remain under the
# diagnostic user/channel below.
export ASWF_PKG_ORG=aswf
export CI_COMMON_VERSION="${ci_common_version}"
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
cd /out

profile="${CONAN_HOME}/profiles/targeted-vfx${year}"
cp "${CONAN_HOME}/profiles/vfx${year}" "${profile}"
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

# Keep optional OpenUSD plugins ABI-compatible with the stock image.  The
# stock profile can enable OSL/OIIO even though the derived image only changes
# OpenUSD and MaterialX; the recipe's historical fixed versions otherwise
# produce plugins linked against a different OIIO/OSL ABI than the base image.
if [[ -n "${oiio_version}" ]]; then
  sed -i -E \
    "s#self\\.requires\\(\\\"openimageio/[^\\\"]+\\\"\\)#self.requires(\\\"openimageio/${oiio_version}\\\")#" \
    "${recipe_root}/openusd/conanfile.py"
fi
if [[ -n "${osl_version}" ]]; then
  sed -i -E \
    "s#self\\.requires\\(\\\"osl/[^\\\"]+\\\"\\)#self.requires(\\\"osl/${osl_version}\\\")#" \
    "${recipe_root}/openusd/conanfile.py"
fi

conan create "${recipe_root}/materialx" \
  --version="${materialx_version}" \
  --user=diagnostic --channel="vfx${year}" \
  --profile:all="${profile}" \
  -o "materialx/*:with_openimageio=True" \
  --build='materialx/*'

conan create "${recipe_root}/openusd" \
  --version="${usd_version}" \
  --user=diagnostic --channel="vfx${year}" \
  --profile:all="${profile}" \
  -o "openusd/*:with_openimageio=True" \
  -o "openusd/*:with_osl=True" \
  --build='openusd/*'

conan install \
  --requires="openusd/${usd_version}@diagnostic/vfx${year}" \
  --profile:all="${profile}" \
  -o "materialx/*:with_openimageio=True" \
  -o "openusd/*:with_openimageio=True" \
  -o "openusd/*:with_osl=True" \
  --deployer-folder="${deploy_root}" \
  --deployer=full_deploy \
  --build=never

usd_dir="$(find "${deploy_root}" -type d -path '*/openusd/*' -name x86_64 -print -quit)"
mtlx_dir="$(find "${deploy_root}" -type d -path '*/materialx/*' -name x86_64 -print -quit)"
[[ -n "${usd_dir}" && -d "${usd_dir}" ]] || { echo "OpenUSD deploy missing" >&2; exit 1; }
[[ -n "${mtlx_dir}" && -d "${mtlx_dir}" ]] || { echo "MaterialX deploy missing" >&2; exit 1; }
cp -a "${usd_dir}/." /out/root/usr/local/
cp -a "${mtlx_dir}/." /out/root/usr/local/

# OpenUSD's OIIO/OSL plugins must run with the exact dependency closure that
# built them.  Overlay every host package from full_deploy, not just the two
# top-level packages: OSL and OIIO depend on Imath, OpenEXR, fmt, LLVM and
# other DSOs whose ABI must remain consistent as well.
while IFS= read -r package_dir; do
  cp -a "${package_dir}/." /out/root/usr/local/
done < <(find "${deploy_root}" -type d -name x86_64 -print)

if [[ -f /out/root/usr/local/plugin/usd/sdrOsl.so ]]; then
  audit=/out/sdrOsl-runtime-audit.txt
  set +e
  {
    echo "=== sdrOsl dynamic section ==="
    readelf -d /out/root/usr/local/plugin/usd/sdrOsl.so
    echo "=== sdrOsl undefined symbols ==="
    nm -D --undefined-only /out/root/usr/local/plugin/usd/sdrOsl.so || true
    echo "=== OIIO ustring providers ==="
    find /out/root/usr/local/lib -maxdepth 1 -type f \
      -name 'libOpenImageIO*.so*' -print -exec nm -D {} \; 2>/dev/null | \
      grep -E 'libOpenImageIO|empty_std_string' || true
    echo "=== ldd -r ==="
    LD_LIBRARY_PATH=/out/root/usr/local/lib:/usr/local/lib \
      ldd -r /out/root/usr/local/plugin/usd/sdrOsl.so 2>&1 || true
    echo "=== no-preload dlopen ==="
    env -u LD_LIBRARY_PATH -u LD_PRELOAD \
      PYTHONPATH=/out/root/usr/local/lib/python \
      PXR_PLUGINPATH_NAME=/out/root/usr/local/plugin/usd \
      python3 -c 'import ctypes; ctypes.CDLL("/out/root/usr/local/plugin/usd/sdrOsl.so", mode=ctypes.RTLD_LOCAL); print("dlopen succeeded")'
    echo "=== pxr.Usd then sdrOsl, no preload, no LD_LIBRARY_PATH ==="
    env -u LD_LIBRARY_PATH -u LD_PRELOAD \
      PYTHONPATH=/out/root/usr/local/lib/python \
      PXR_PLUGINPATH_NAME=/out/root/usr/local/plugin/usd \
      python3 -c 'import ctypes; import pxr.Usd; ctypes.CDLL("/out/root/usr/local/plugin/usd/sdrOsl.so", mode=ctypes.RTLD_LOCAL); print("pxr.Usd then sdrOsl succeeded")'
  } >"${audit}" 2>&1
  audit_status=$?
  set -e
  cat "${audit}"
  if [[ "${audit_status}" != 0 ]] || ! grep -q 'dlopen succeeded' "${audit}" || \
     ! grep -q 'pxr.Usd then sdrOsl succeeded' "${audit}"; then
    echo "sdrOsl no-preload dlopen failed; see audit above" >&2
    exit 1
  fi
fi

{
  echo "vfxplatform=${year}"
  echo "openusd=${usd_version}"
  echo "materialx=${materialx_version}"
  echo "openimageio=${oiio_version:-stock-profile} enabled=true"
  echo "osl=${osl_version:-stock-profile} enabled=true"
  echo "jobs=${jobs}"
  conan --version
} > /out/targeted-build-provenance.txt

rm -rf "${CONAN_HOME}" "${recipe_root}" "${deploy_root}"
