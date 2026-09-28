#!/usr/bin/env bash
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
finish() {
  result=$?
  trap - EXIT
  printf '%s\n' "$result" > /out/status.txt
  if test -d /tmp/issue50-runtime; then
    cp -a /tmp/issue50-runtime/. /out/
  fi
  exit "$result"
}
trap finish EXIT
lscpu
c++ /evidence/rdtscp-probe.cpp -o /tmp/rdtscp-probe
/tmp/rdtscp-probe
timeout 300 dnf --disablerepo=cuda install -y libepoxy-devel
bash /evidence/configure-cycles.sh
timeout 3600 cmake --build /tmp/issue50-cycles-build --target hdCycles --parallel 2
sha256sum /tmp/issue50-cycles-build/src/hydra/hdCycles.so
bash /evidence/validate-runtime.sh
