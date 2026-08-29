#!/usr/bin/env bash
# Image-closure validation for the hdEmbree delegate images.
# Runs INSIDE the container, piped via stdin:
#   docker run -i --rm --env USD_VERSION_MAJOR=25 IMAGE bash -s -- 25 < ci-embree/validate_image.sh
set -euxo pipefail

: "${USD_VERSION_MAJOR:?USD_VERSION_MAJOR is required (pass as argument 1 or env)}"

test -f /opt/embree/lib/libembree3.so
test -f /opt/hdembree/hydra/hdEmbree.so
test -f /opt/hdembree/hydra/plugInfo.json
test -f /opt/hdembree/hydra/hdEmbree/resources/plugInfo.json

# token substitution completed and the delegate is registered
! grep -q "@PLUG_INFO" /opt/hdembree/hydra/hdEmbree/resources/plugInfo.json
grep -q '"Embree"' /opt/hdembree/hydra/hdEmbree/resources/plugInfo.json
grep -q '"Includes"' /opt/hdembree/hydra/plugInfo.json

LD_LIBRARY_PATH="/opt/embree/lib:/usr/local/lib:/usr/local/lib64" \
  ldd -r /opt/hdembree/hydra/hdEmbree.so | tee /tmp/hdEmbree-ldd.txt
! grep -Eq "not found|undefined symbol" /tmp/hdEmbree-ldd.txt
grep -q "libembree3" /tmp/hdEmbree-ldd.txt

# The delegate must link the same TBB soname the installed pxr libs use
# (two TBBs in one process would be fatal).  Read the expectation from the
# installed stack instead of hardcoding a year-specific soname.
pxr_tbb_soname="$(ldd /usr/local/lib/libusd_work.so \
  | sed -n 's/.*\(libtbb\.so\.[0-9]*\).*/\1/p' | head -1)"
printf 'pxr TBB soname: %s\n' "$pxr_tbb_soname"
test -n "$pxr_tbb_soname"
grep -q "$pxr_tbb_soname" /tmp/hdEmbree-ldd.txt
! grep -oE 'libtbb\.so\.[0-9]+' /tmp/hdEmbree-ldd.txt \
  | sort -u | grep -qv "^${pxr_tbb_soname}$"

# OpenUSD version of the consumed stack (conan builds report 0.Y.Z style
# tuples; accept either shape against the expected major).
PYTHONPATH=/usr/local/lib/python python3 - "$USD_VERSION_MAJOR" <<'PYEOF'
import sys
from pxr import Usd

major = int(sys.argv[1])
v = Usd.GetVersion()
t = tuple(v) if isinstance(v, (tuple, list)) else tuple(
    int(p) for p in str(v).split(".")[:3])
print("OpenUSD version:", v)
assert t[0] == major or (t[0] == 0 and t[1] == major), t
PYEOF

echo "image closure OK"
