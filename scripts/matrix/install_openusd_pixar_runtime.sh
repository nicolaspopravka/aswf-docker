#!/usr/bin/env bash

set -euo pipefail

cy="${1:?CY is required}"
expected_python="${2:?expected Python version is required}"
pyside_version="${3:?PySide version or none is required}"
pyside_lock="${4:?PySide lock name or none is required}"
parent_image="${5:?parent image is required}"

runtime_root="/opt/openusd-runtime"
evidence_root="/opt/openusd-runtime-evidence"
build_evidence="/opt/openusd-build-evidence"
python_bin="/usr/local/bin/python3"

mkdir -p "${evidence_root}"

[[ "${OPENUSD_MATRIX_BUILD_PATH:-}" == "pixar-build-usd" ]]
[[ "${OPENUSD_MATRIX_CY:-}" == "${cy}" ]]
[[ -x "${python_bin}" ]]
[[ -d "${build_evidence}/runtime" ]]

observed_python="$("${python_bin}" -c 'import platform; print(platform.python_version())')"
[[ "${observed_python}" == "${expected_python}" ]]

record_openusd_hashes() {
  output="$1"
  {
    sha256sum /usr/local/bin/usdrecord /usr/local/bin/usdcat
    while IFS= read -r library; do
      [[ -f "${library}" ]]
      sha256sum "${library}"
    done < "${build_evidence}/runtime/openusd-libraries.txt"
    while IFS= read -r plugin_info; do
      [[ -f "${plugin_info}" ]]
      sha256sum "${plugin_info}"
    done < "${build_evidence}/runtime/plugin-info-files.txt"
    pxr_init="$("${python_bin}" -c 'import pxr; print(pxr.__file__)')"
    sha256sum "${pxr_init}"
  } | LC_ALL=C sort -u > "${output}"
}

record_openusd_hashes "${evidence_root}/openusd-before.sha256"

{
  printf 'cy=%s\n' "${cy}"
  printf 'parent_image=%s\n' "${parent_image}"
  printf 'python_version=%s\n' "${observed_python}"
  printf 'pyside_version=%s\n' "${pyside_version}"
  printf 'pyside_lock=%s\n' "${pyside_lock}"
} > "${evidence_root}/inputs.txt"

find "/usr/local/lib/python${observed_python%.*}/ensurepip/_bundled" \
  -maxdepth 1 -type f -name '*.whl' -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 sha256sum > "${evidence_root}/ensurepip-wheels.sha256"

"${python_bin}" -m ensurepip --upgrade \
  2>&1 | tee "${evidence_root}/ensurepip.log"
"${python_bin}" -m pip --version \
  > "${evidence_root}/pip-version.txt"

if [[ "${pyside_version}" == "none" ]]; then
  [[ "${pyside_lock}" == "none" ]]
  printf 'not required by the established CY%s EGL wrapper\n' "${cy}" \
    > "${evidence_root}/pyside-status.txt"
else
  [[ "${pyside_lock}" != "none" ]]
  lock_path="${runtime_root}/${pyside_lock}"
  [[ -f "${lock_path}" ]]
  cp "${lock_path}" "${evidence_root}/pyside.lock"
  sha256sum "${evidence_root}/pyside.lock" \
    > "${evidence_root}/pyside-lock.sha256"
  "${python_bin}" -m pip install \
    --disable-pip-version-check \
    --no-cache-dir \
    --only-binary=:all: \
    --require-hashes \
    --requirement "${lock_path}" \
    2>&1 | tee "${evidence_root}/pyside-install.log"
  "${python_bin}" - "${pyside_version}" \
    > "${evidence_root}/pyside-status.txt" <<'PY'
import sys
import PySide6
from PySide6.QtWidgets import QApplication

expected = sys.argv[1]
assert PySide6.__version__ == expected, (PySide6.__version__, expected)
print(f"PySide6={PySide6.__version__}")
print(f"QApplication={QApplication.__module__}.{QApplication.__name__}")
PY
fi

record_openusd_hashes "${evidence_root}/openusd-after.sha256"
diff -u \
  "${evidence_root}/openusd-before.sha256" \
  "${evidence_root}/openusd-after.sha256" \
  > "${evidence_root}/openusd-hash-diff.txt"

(
  cd "${evidence_root}"
  find . -type f ! -name evidence-sha256.txt -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum \
    > evidence-sha256.txt
)
