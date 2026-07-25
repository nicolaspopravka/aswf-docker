#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
matrix_root="${repo_root}/scripts/matrix"
workflow="${repo_root}/.github/workflows/openusd-pixar-runtime-overlays.yml"

python3 "${matrix_root}/openusd_pixar_runtime_overlays.py" validate
(
  cd "${matrix_root}"
  PYTHONDONTWRITEBYTECODE=1 \
    python3 -m unittest test_openusd_pixar_runtime_overlays.py
)
bash -n "${matrix_root}/install_openusd_pixar_runtime.sh"

pilot="$(
  python3 "${matrix_root}/openusd_pixar_runtime_overlays.py" \
    select --scope pilot
)"
all="$(
  python3 "${matrix_root}/openusd_pixar_runtime_overlays.py" \
    select --scope all
)"
python3 -c '
import json, sys
pilot = json.loads(sys.argv[1])["include"]
all_entries = json.loads(sys.argv[2])["include"]
assert [entry["cy"] for entry in pilot] == [2025]
assert [entry["cy"] for entry in all_entries] == [2023, 2024, 2025, 2026, 2027]
assert all("@sha256:" in entry["parent_image"] for entry in all_entries)
' "${pilot}" "${all}"

grep -Fq 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' \
  "${workflow}"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
  "${workflow}"
grep -Fq 'permissions:' "${workflow}"
grep -Fq 'packages: write' "${workflow}"
grep -Fq 'cancel-in-progress: false' "${workflow}"
grep -Fq 'PARENT_IMAGE: ${{ matrix.parent_image }}' "${workflow}"
grep -Fq -- '--build-arg PARENT_IMAGE="$PARENT_IMAGE"' "${workflow}"
grep -Fq 'docker push "$TARGET_IMAGE"' "${workflow}"
grep -Fq '/opt/openusd-runtime-evidence/.' "${workflow}"

echo "OpenUSD Pixar runtime overlay validation passed"
