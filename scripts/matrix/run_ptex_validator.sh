#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cxx="${CXX:-c++}"
asan_library="${MOANA_ASAN_LIBRARY:-$("${cxx}" -print-file-name=libasan.so)}"
[[ "${asan_library}" = /* && -f "${asan_library}" ]] || {
  echo "ASan runtime not found: ${asan_library}" >&2
  exit 2
}

export LD_PRELOAD="${asan_library}${LD_PRELOAD:+:${LD_PRELOAD}}"
exec /opt/moana-debug/validate_ptex_file_asan "$@"
