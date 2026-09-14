#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
output_root="${1:?output directory required}"
mkdir -p "${output_root}"
export PYTHONPATH="/usr/local/lib/python${PYTHONPATH:+:${PYTHONPATH}}"
unset LD_PRELOAD
for mode in default explicit-stdlib; do
    if [[ "${mode}" == default ]]; then
        unset PXR_MTLX_STDLIB_SEARCH_PATHS
    else
        export PXR_MTLX_STDLIB_SEARCH_PATHS=/usr/local/share/MaterialX/libraries
    fi
    for operation in stage registry; do
        status=0
        timeout -k 10 150 python3 -u /probe/issue10_discovery.py "${operation}" \
            > "${output_root}/${mode}-${operation}.log" 2>&1 || status=$?
        echo "${status}" > "${output_root}/${mode}-${operation}.status"
    done
done
