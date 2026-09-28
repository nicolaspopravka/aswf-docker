#!/usr/bin/env bash
# Bounded CPU smoke check, only after hdCycles has built successfully.
set -euo pipefail
build=/tmp/issue50-cycles-build
stage=/tmp/issue50-runtime
mkdir -p "$stage/hydra/hdCycles/resources"
# Stage only the compiled plugin and its generated registration metadata.
# This does not claim acceptance of the complete Cycles installation target.
cp "$build/src/hydra/hdCycles.so" "$stage/hydra/"
cp /cycles/src/hydra/plugInfo.json "$stage/hydra/"
cp "$build/src/hydra/resources/plugInfo.json" "$stage/hydra/hdCycles/resources/"
export PXR_PLUGINPATH_NAME="$stage/hydra"
export CYCLES_DEVICE=CPU
ldd -r "$stage/hydra/hdCycles.so"
python3 - <<'PY'
from pxr import Plug
plugin = Plug.Registry().GetPluginWithName("hdCycles")
assert plugin is not None
assert plugin.path == "/tmp/issue50-runtime/hydra/hdCycles.so", plugin.path
assert plugin.Load()
print("CANDIDATE_PLUGIN_LOAD_PASS", plugin.path)
PY
timeout 180 usdrecord --disableGpu --renderer Cycles --camera /Camera \
  --imageWidth 64 --colorCorrectionMode disabled \
  /evidence/smoke.usda "$stage/smoke.png"
test -s "$stage/smoke.png"
echo CANDIDATE_RENDER_COMMAND_PASS
