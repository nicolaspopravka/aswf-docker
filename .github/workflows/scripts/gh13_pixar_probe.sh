#!/usr/bin/env bash
# GH #13 Pixar-side dome-light probe (CY2023).
# Run either (a) on the pixar CY2023 pod, or (b) inside the pixar runtime
# container via GitHub Actions (free) — the script takes the texture path and
# output dir as arguments so it is venue-agnostic.
#
#   bash gh13_pixar_probe.sh [TEX] [OUTDIR]
#     TEX    path to nuke_texture_export.exr
#            (default: volume layout used by the benchmark pods)
#     OUTDIR directory to write the log into (default: current dir)
#
# Captures versions, oiiotool open/read behavior, and the exact OIIO error.
set -u

TEX="${1:-/workspace/usd-render-benchmark/scenes/ALab/ALab/fragment/lightrig/lighting/mk020_0281_export/base/texture/dmp_skydome_alab01_std01_render_high_texture/nuke_texture_export.exr}"
OUTDIR="${2:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$OUTDIR/gh13-pixar-probe-$(date +%Y%m%d-%H%M%S).log"

{
echo "===== GH #13 Pixar probe: $(date -u) ====="
echo "HOST: $(hostname)"
echo

echo "----- [1] file presence -----"
ls -l "$TEX" || { echo "MISSING TEXTURE: $TEX"; exit 1; }

echo
echo "----- [2] versions -----"
for b in oiiotool exrheader iinfo pxr-config; do
  p=$(command -v $b 2>/dev/null) || { echo "$b: (not found)"; continue; }
  echo "$b: $p"
  "$b" --version 2>&1 | head -1
done
echo "OpenEXR/OIIO shared libs:"
ldconfig -p 2>/dev/null | grep -iE "OpenEXR|OpenImageIO|Imath" | head -15

echo
echo "----- [3] oiiotool info (-a lists all mip levels) -----"
if command -v oiiotool >/dev/null 2>&1; then
  oiiotool -i -a --info "$TEX" 2>&1 | head -40
  echo "oiiotool --info exit: ${PIPESTATUS[0]}"

  echo
  echo "----- [4] oiiotool full read (pixel decode path) -----"
  oiiotool -i "$TEX" -o /tmp/skydome_decoded.exr 2>&1 | head -20
  echo "oiiotool read exit: ${PIPESTATUS[0]}"
  [ -f /tmp/skydome_decoded.exr ] && ls -l /tmp/skydome_decoded.exr
else
  echo "(oiiotool not on PATH)"
fi

echo
echo "----- [5] HioImage C++ probe (exact dome-light path) -----"
if [ -f "$SCRIPT_DIR/gh13_pixar_probe.cpp" ]; then
  g++ -std=c++17 -o /tmp/hio_probe "$SCRIPT_DIR/gh13_pixar_probe.cpp" \
    $(pxr-config --cflags --libs 2>/dev/null) 2>/dev/null
  if [ -x /tmp/hio_probe ]; then
    /tmp/hio_probe "$TEX"
  else
    echo "(HioImage probe compile failed; pxr-config/libs not resolvable here)"
  fi
fi

echo
echo "----- [6] bare OIIO C++ probe (OpenEXR input plugin, geterror) -----"
if [ -f "$SCRIPT_DIR/gh13_pixar_oiio_probe.cpp" ]; then
  g++ -std=c++17 -o /tmp/oiio_probe "$SCRIPT_DIR/gh13_pixar_oiio_probe.cpp" \
    $(pkg-config --cflags --libs OpenImageIO 2>/dev/null) 2>/dev/null
  if [ ! -x /tmp/oiio_probe ] && [ -d /usr/local/include/OpenImageIO ]; then
    g++ -std=c++17 -o /tmp/oiio_probe "$SCRIPT_DIR/gh13_pixar_oiio_probe.cpp" \
      -I/usr/local/include -L/usr/local/lib -Wl,-rpath,/usr/local/lib -lOpenImageIO 2>/dev/null
  fi
  if [ -x /tmp/oiio_probe ]; then
    /tmp/oiio_probe "$TEX"
  else
    echo "(bare OIIO probe compile failed too — capture tool versions manually)"
  fi
fi

echo
echo "----- [7] shared libs behind the EXR read -----"
ldd /usr/local/bin/oiiotool 2>/dev/null | grep -iE "exr|oiio|osl|Imath" | head -10

echo
echo "===== probe done ====="
} 2>&1 | tee "$LOG"

echo
echo "Log saved to: $LOG"
