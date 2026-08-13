#!/usr/bin/env bash
# GH #23 gdb probe: attribute the empty VtValue reaching hdMoonray's
# Light::Sync (.Get<TfToken>() for lightLink/shadowLink) to a specific
# delegate/adapter implementation, in both default (scene-index emulation ON)
# and HD_ENABLE_SCENE_INDEX_EMULATION=0 modes.
#
# Breaks on:
#   UsdImagingDelegate::GetLightParamValue              (classic delegate)
#   HdSceneIndexAdapterSceneDelegate::GetLightParamValue (scene-index adapter)
#   UsdImagingPrimAdapter::GetLightParamValue           (usdImaging adapter)
#   VtValue::_FailGet                                   (the failure point)
#
# No debug info in the shipped libs, so args are decoded via the SysV x86-64
# ABI at function entry from registers:
#   non-static member, 2 ref args: RDI=this, RSI=&id, RDX=&paramName
#   UsdImagingPrimAdapter (const, 4 args): RDI=this, RSI=&usdPrim,
#       RDX=&cachePath, RCX=&paramName, R8=time
#
# TfToken layout (25.05): _rep = *(uint64*)&tok & ~3; std::string _str at
# offset 16 in _Rep; string data ptr at *(char**)(rep+16). SdfPath: 8-byte
# node handle, 0 == empty path.
#
# CPU-only; free GitHub Actions.
set -u

SCENE="${1:-/validation/minimal.usda}"
OUT="${2:-/probeout}"

export LIBGL_ALWAYS_SOFTWARE=1
export MESA_GL_VERSION_OVERRIDE=4.5

mkdir -p "$OUT"

if ! command -v gdb >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install gdb >/dev/null 2>&1 || dnf -y --allowerasing install gdb >/dev/null 2>&1
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf -y install gdb >/dev/null 2>&1
  fi
fi

DELEGATE_SYM='_ZN34pxrInternal_v0_25_5__pxrReserved__18UsdImagingDelegate18GetLightParamValueERKNS_7SdfPathERKNS_7TfTokenE'
SI_SYM='_ZN34pxrInternal_v0_25_5__pxrReserved__32HdSceneIndexAdapterSceneDelegate18GetLightParamValueERKNS_7SdfPathERKNS_7TfTokenE'
ADAPTER_SYM='_ZNK34pxrInternal_v0_25_5__pxrReserved__21UsdImagingPrimAdapter18GetLightParamValueERKNS_7UsdPrimERKNS_7SdfPathERKNS_7TfTokenENS_11UsdTimeCodeE'
FAILGET_SYM='_ZNK34pxrInternal_v0_25_5__pxrReserved__7VtValue8_FailGetEPFNS_21Vt_DefaultValueHolderEvERKSt9type_info'

python3_bin=$(command -v python3)
script_bin=$(command -v usdrecord)

echo "=== Shipped symbol presence (evidence that shipped libs differ from local source tags if behavior differs) ==="
for lib in /usr/local/lib/libusd_usdImaging.so /usr/local/lib/libusd_hd.so; do
  echo "--- $lib ---"
  nm -D "$lib" 2>/dev/null | grep -E "GetLightParamValue|_FailGet" | sed 's/^/  /'
done
echo

for mode in default emu0; do
  if [ "$mode" = emu0 ]; then
    export HD_ENABLE_SCENE_INDEX_EMULATION=0
  else
    unset HD_ENABLE_SCENE_INDEX_EMULATION
  fi

  for renderer in "Moonray" "Moonray (debug)"; do
    tag=$(echo "$mode-$renderer" | tr ' ()' '___')
    echo "===== gdb delegate-param: mode=$mode renderer=$renderer ($tag) ====="
    cat > "/tmp/gdb-$tag.cmd" <<EOF
set pagination off
set confirm off
set breakpoint pending on
file ${python3_bin}
set args ${script_bin} --renderer "${renderer}" --camera /World/Camera --imageWidth 256 ${SCENE} ${OUT}/minimal-${tag}.exr
break ${DELEGATE_SYM}
commands
silent
printf "\\n=== HIT UsdImagingDelegate::GetLightParamValue ===\\n"
printf "  id bits=0x%lx (0 == EMPTY path)\\n", *(unsigned long*)\$rsi
set \$rep = (*(unsigned long*)\$rdx) & ~3ul
if \$rep != 0
  x/s *(char**)((unsigned long)\$rep + 16)
else
  printf "  paramName rep=0 (EMPTY TOKEN)\\n"
end
bt 6
printf "=== END DELEGATE ===\\n"
continue
end
break ${SI_SYM}
commands
silent
printf "\\n=== HIT HdSceneIndexAdapterSceneDelegate::GetLightParamValue ===\\n"
printf "  id bits=0x%lx (0 == EMPTY path)\\n", *(unsigned long*)\$rsi
set \$rep = (*(unsigned long*)\$rdx) & ~3ul
if \$rep != 0
  x/s *(char**)((unsigned long)\$rep + 16)
else
  printf "  paramName rep=0 (EMPTY TOKEN)\\n"
end
bt 6
printf "=== END SI ADAPTER ===\\n"
continue
end
break ${ADAPTER_SYM}
commands
silent
printf "\\n=== HIT UsdImagingPrimAdapter::GetLightParamValue ===\\n"
printf "  cachePath bits=0x%lx (0 == EMPTY path)\\n", *(unsigned long*)\$rdx
set \$rep = (*(unsigned long*)\$rcx) & ~3ul
if \$rep != 0
  x/s *(char**)((unsigned long)\$rep + 16)
else
  printf "  paramName rep=0 (EMPTY TOKEN)\\n"
end
bt 6
printf "=== END ADAPTER ===\\n"
continue
end
break ${FAILGET_SYM}
commands
silent
printf "\\n=== HIT _FailGet ===\\n"
bt 8
printf "=== END FAILGET ===\\n"
continue
end
run
EOF
    set +e
    timeout -k 15 900 xvfb-run -a gdb -batch -x "/tmp/gdb-$tag.cmd" \
      > "$OUT/gdb-$tag.log" 2>&1
    status=$?
    set -e
    echo "$status" > "$OUT/gdb-$tag.exit"
    echo "exit=$status"
    echo "delegate hits:  $(grep -c '=== HIT UsdImagingDelegate' "$OUT/gdb-$tag.log" || true)"
    echo "SI adapter hits: $(grep -c '=== HIT HdSceneIndexAdapterSceneDelegate' "$OUT/gdb-$tag.log" || true)"
    echo "adapter hits:   $(grep -c '=== HIT UsdImagingPrimAdapter' "$OUT/gdb-$tag.log" || true)"
    echo "FailGet hits:   $(grep -c '=== HIT _FailGet' "$OUT/gdb-$tag.log" || true)"
    echo
  done
done
