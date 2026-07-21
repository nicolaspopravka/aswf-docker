#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -uo pipefail

evidence_root="${1:?evidence directory required}"
mkdir -p "${evidence_root}/metadata" "${evidence_root}/logs"
export PATH="/usr/local/bin:${PATH}"
export PYTHONPATH="/usr/local/lib/python${PYTHONPATH:+:${PYTHONPATH}}"

run_capture() {
  local output="$1"
  shift
  set +e
  "$@" >"${output}" 2>&1
  local status=$?
  set -e
  echo "${status}" >"${output%.log}.exit"
  return 0
}

find_candidates() {
  find /usr/local /opt -type f -o -type l 2>/dev/null | while IFS= read -r path; do
    case "${path##*/}" in
      libOpenImageIO*.so*|libosl*.so*|libOSL*.so*|sdrOsl.so)
        printf '%s\n' "${path}"
        ;;
    esac
  done | sort -u
}

{
  echo "IMAGE_YEAR=${IMAGE_YEAR:-unset}"
  echo "IMAGE=${DIAGNOSTIC_IMAGE:-unset}"
  echo "PATH=${PATH:-unset}"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-unset}"
  echo "LD_PRELOAD=${LD_PRELOAD:-unset}"
  echo "PYTHONPATH=${PYTHONPATH:-unset}"
  echo "=== versions ==="
  python3 --version || true
  command -v usdrecord || true
  echo "=== package candidates ==="
  find_candidates
} >"${evidence_root}/metadata/environment.txt" 2>&1

find_candidates >"${evidence_root}/metadata/library-candidates.txt"
while IFS= read -r candidate; do
  safe_name="$(printf '%s' "${candidate}" | sed 's#^/##; s#[^A-Za-z0-9_.-]#_#g')"
  {
    echo "PATH=${candidate}"
    readlink -f "${candidate}" || true
    file "${candidate}" || true
    sha256sum "${candidate}" 2>/dev/null || true
    echo "=== dynamic section ==="
    readelf -d "${candidate}" 2>&1 || true
    case "${candidate##*/}" in
      libOpenImageIO_Util.so*)
        echo "=== exported ustring symbol ==="
        nm -D --defined-only "${candidate}" 2>&1 |
          grep 'empty_std_string' || true
        ;;
      sdrOsl.so|liboslquery.so*)
        echo "=== undefined symbols ==="
        nm -D --undefined-only "${candidate}" 2>&1 |
          grep -E 'empty_std_string|OpenImageIO|osl' || true
        echo "=== ldd -r ==="
        ldd -r "${candidate}" 2>&1 || true
        ;;
    esac
  } >"${evidence_root}/metadata/${safe_name}.txt" 2>&1
done <"${evidence_root}/metadata/library-candidates.txt"

run_capture "${evidence_root}/logs/pxr_usd_then_sdrOsl.log" \
  env LD_DEBUG=libs,symbols python3 -c \
  'import ctypes; import pxr.Usd; ctypes.CDLL("/usr/local/plugin/usd/sdrOsl.so", mode=ctypes.RTLD_LOCAL); print("sdrOsl dlopen succeeded")'

oiio_util="$(find /usr/local /opt -type f -name 'libOpenImageIO_Util.so*' -print 2>/dev/null | sort | head -n 1)"
oslquery="$(find /usr/local /opt -type f -name 'liboslquery.so*' -print 2>/dev/null | sort | head -n 1)"
if [[ -n "${oiio_util}" && -n "${oslquery}" ]]; then
  run_capture "${evidence_root}/logs/pxr_usd_then_sdrOsl_preload.log" \
    env LD_PRELOAD="${oiio_util}:${oslquery}" python3 -c \
    'import ctypes; import pxr.Usd; ctypes.CDLL("/usr/local/plugin/usd/sdrOsl.so", mode=ctypes.RTLD_LOCAL); print("preload sdrOsl dlopen succeeded")'
else
  echo "missing preload candidates" >"${evidence_root}/logs/pxr_usd_then_sdrOsl_preload.log"
  echo 127 >"${evidence_root}/logs/pxr_usd_then_sdrOsl_preload.exit"
fi

run_capture "${evidence_root}/logs/usdrecord_help.log" \
  env LD_DEBUG=libs usdrecord --help

exit 0
