#!/usr/bin/env bash
# GH #23 cross-delegate probe: run the SAME minimal scene through
# Moonray (Arras), "Moonray (debug)" (in-process), and Storm in the same
# image, and compare the empty-TfToken / invalid-framebuffer diagnostics.
# Goal: isolate whether the post-render sequence is MoonRay/Arras-specific
# or OpenUSD/hgiGL-wide. CPU-only; runs via GitHub Actions (free).
set -u

SCENE="${1:-/validation/minimal.usda}"
OUT="${2:-/probeout}"

export LIBGL_ALWAYS_SOFTWARE=1
export MESA_GL_VERSION_OVERRIDE=4.5
export LD_PRELOAD=/usr/local/lib/libOpenImageIO_Util.so:/usr/local/lib/liboslquery.so

mkdir -p "$OUT"

for renderer in "Moonray" "Moonray (debug)" "Storm"; do
  tag=$(echo "$renderer" | tr ' ()' '___')
  echo "===== delegate: $renderer ($tag) ====="
  set +e
  timeout -k 15 600 xvfb-run -a usdrecord \
    --renderer "$renderer" \
    --camera /World/Camera \
    --imageWidth 256 \
    "$SCENE" \
    "$OUT/minimal-$tag.exr" \
    > "$OUT/minimal-$tag.log" 2>&1
  status=$?
  set -e
  echo "$status" > "$OUT/minimal-$tag.exit"
  echo "exit=$status"
  echo "TfToken_empty_count=$(grep -c "empty VtValue" "$OUT/minimal-$tag.log" || true)"
  echo "invalid_framebuffer_count=$(grep -c "invalid framebuffer" "$OUT/minimal-$tag.log" || true)"
  if [ -f "$OUT/minimal-$tag.exr" ]; then
    python3 /validation/image_stats.py --require-variation \
      "$OUT/minimal-$tag.exr" 2>&1 | tee "$OUT/minimal-$tag.stats.json"
  else
    echo "NO IMAGE"
  fi
  echo
done

echo "===== comparison summary ====="
for renderer in "Moonray" "Moonray (debug)" "Storm"; do
  tag=$(echo "$renderer" | tr ' ()' '___')
  tok=$(grep -c "empty VtValue" "$OUT/minimal-$tag.log" || true)
  fbo=$(grep -c "invalid framebuffer" "$OUT/minimal-$tag.log" || true)
  ex=$(cat "$OUT/minimal-$tag.exit")
  echo "$renderer: TfToken_empty=$tok invalid_framebuffer=$fbo exit=$ex"
done
