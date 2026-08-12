#!/usr/bin/env bash
# GH #23 probe: toggle HD_ENABLE_SCENE_INDEX_EMULATION / engine scene-index
# env vars and re-run the minimal scene through Moonray + "Moonray (debug)".
# If the empty-TfToken _FailGet comes from the scene-index emulation adapter
# (HdSceneIndexAdapterSceneDelegate::GetLightParamValue returning VtValue() for
# lightLink/shadowLink), disabling emulation clears the errors.
# CPU-only; runs via GitHub Actions (free).
set -u

SCENE="${1:-/validation/minimal.usda}"
OUT="${2:-/probeout}"

export LIBGL_ALWAYS_SOFTWARE=1
export MESA_GL_VERSION_OVERRIDE=4.5
export LD_PRELOAD=/usr/local/lib/libOpenImageIO_Util.so:/usr/local/lib/liboslquery.so

mkdir -p "$OUT"

# env-config-name: env var settings (empty value = unset)
run_config() {
  local cfg="$1"; shift
  local renderer="$1"; shift
  # remaining args are "KEY=value" pairs
  local tag
  tag=$(echo "$renderer" | tr ' ()' '___')
  local cfg_tag
  cfg_tag=$(echo "$cfg" | tr ' ' '_')
  local log="$OUT/$cfg_tag-$tag.log"

  echo "===== cfg=$cfg renderer=$renderer ====="
  set +e
  env "$@" \
    timeout -k 15 600 xvfb-run -a usdrecord \
      --renderer "$renderer" \
      --camera /World/Camera \
      --imageWidth 256 \
      "$SCENE" \
      "$OUT/$cfg_tag-$tag.exr" \
      > "$log" 2>&1
  status=$?
  set -e
  echo "$status" > "$OUT/$cfg_tag-$tag.exit"
  echo "exit=$status"
  echo "TfToken_empty_count=$(grep -c "empty VtValue" "$log" || true)"
  echo "invalid_framebuffer_count=$(grep -c "invalid framebuffer" "$log" || true)"
  if [ -f "$OUT/$cfg_tag-$tag.exr" ]; then
    python3 /validation/image_stats.py --require-variation \
      "$OUT/$cfg_tag-$tag.exr" 2>&1 | tee "$OUT/$cfg_tag-$tag.stats.json"
  else
    echo "NO IMAGE"
  fi
  echo
}

# baseline: current image defaults (HD_ENABLE_SCENE_INDEX_EMULATION=true)
for renderer in "Moonray" "Moonray (debug)"; do
  run_config baseline "$renderer"
done

# scene-index emulation OFF -> classic UsdImagingDelegate path
for renderer in "Moonray" "Moonray (debug)"; do
  run_config emu0 "$renderer" HD_ENABLE_SCENE_INDEX_EMULATION=0
done

# force engine full scene-index path (needs emulation enabled, which is default)
for renderer in "Moonray" "Moonray (debug)"; do
  run_config si1 "$renderer" USDIMAGINGGL_ENGINE_ENABLE_SCENE_INDEX=1
done

echo "===== comparison summary ====="
printf "%-40s %-22s %-18s %-6s\n" "cfg-renderer" "TfToken_empty" "invalid_fbo" "exit"
for cfg in baseline emu0 si1; do
  for renderer in "Moonray" "Moonray (debug)"; do
    tag=$(echo "$renderer" | tr ' ()' '___')
    log="$OUT/$cfg-$tag.log"
    tok=$(grep -c "empty VtValue" "$log" || true)
    fbo=$(grep -c "invalid framebuffer" "$log" || true)
    ex=$(cat "$OUT/$cfg-$tag.exit")
    printf "%-40s %-22s %-18s %-6s\n" "$cfg/$renderer" "$tok" "$fbo" "$ex"
  done
done
