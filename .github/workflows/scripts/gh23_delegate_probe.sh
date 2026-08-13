#!/usr/bin/env bash
# GH #23 gdb probe v3: capture the RETURN VALUE of each GetLightParamValue
# implementation and identify the paramName token.
#
# v2 established: every GetLightParamValue call comes from hdMoonray::Light::Sync;
# _FailGet fires 2x in BOTH default and emu0 modes; paramName slot reads 0x700
# (not a valid string pointer).
#
# This version:
#   - prints ALL arg registers + raw token bytes (x/2gx) + `info symbol`
#     resolution of the paramName pointer and rep value
#   - runs `finish` at each breakpoint and prints the RETURN VtValue:
#       RAX = VtValue::_info (0 == EMPTY VtValue)
#       RDX = VtValue::_storage low word (TfToken _rep if _info != 0)
#   - at _FailGet, dumps the empty VtValue object (RDI) and disassembles
#     Light::Sync around the call site (frame 1) to expose both
#     GetLightParamValue calls and the tokens passed.
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

echo "=== Shipped symbol presence ==="
for lib in /usr/local/lib/libusd_usdImaging.so /usr/local/lib/libusd_hd.so; do
  echo "--- $lib ---"
  nm -D "$lib" 2>/dev/null | grep -E "GetLightParamValue|_FailGet" | sed 's/^/  /'
done
echo

# Token/decode body for the delegate + SI adapter breakpoints.
# 2-arg member: RDI=this (or sret), RSI=&id, RDX=&paramName.
# We print every relevant register + raw memory, then `finish` to capture the
# VtValue return (RAX=_info, RDX=_storage).
CAPTURE_BODY=$(cat <<'XEOF'
  printf "  REGS rdi=0x%lx rsi=0x%lx rdx=0x%lx rcx=0x%lx\n", $rdi, $rsi, $rdx, $rcx
  info symbol $rdx
  printf "  raw token object at param_ptr:\n"
  x/2gx $rdx
  set $p = (unsigned long)$rdx
  set $ok = 0
  if $p > 0x100000 && $p < 0x00007fffffffffff
    set $ok = 1
  end
  if $ok
    set $rep = (*(unsigned long*)$p) & ~3ul
    printf "  paramName rep (masked) = 0x%lx\n", $rep
    info symbol $rep
  end
  set $idok = 0
  if (unsigned long)$rsi > 0x100000 && (unsigned long)$rsi < 0x00007fffffffffff
    set $idok = 1
  end
  if $idok
    printf "  id node handle = 0x%lx (0 == EMPTY path)\n", *(unsigned long*)$rsi
  end
  finish
  printf "  RETURN VtValue: rax(_info)=0x%lx rdx(_storage)=0x%lx\n", $rax, $rdx
  if $rax == 0
    printf "  >>> RETURNED EMPTY VtValue (this is what triggers _FailGet)\n"
  else
    printf "  VtValue holds a value; storage word 0x%lx = rep if TfToken\n", $rdx
    info symbol $rdx
  end
XEOF
)

for mode in default emu0; do
  if [ "$mode" = emu0 ]; then
    export HD_ENABLE_SCENE_INDEX_EMULATION=0
  else
    unset HD_ENABLE_SCENE_INDEX_EMULATION
  fi

  for renderer in "Moonray" "Moonray (debug)"; do
    tag=$(echo "$mode-$renderer" | tr ' ()' '___')
    echo "===== gdb delegate-param v3: mode=$mode renderer=$renderer ($tag) ====="
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
${CAPTURE_BODY}
printf "=== END DELEGATE ===\\n"
continue
end
break ${SI_SYM}
commands
silent
printf "\\n=== HIT HdSceneIndexAdapterSceneDelegate::GetLightParamValue ===\\n"
${CAPTURE_BODY}
printf "=== END SI ADAPTER ===\\n"
continue
end
break ${ADAPTER_SYM}
commands
silent
printf "\\n=== HIT UsdImagingPrimAdapter::GetLightParamValue ===\\n"
printf "  REGS rdi=0x%lx rsi=0x%lx rdx=0x%lx rcx=0x%lx r8=0x%lx\\n", \$rdi, \$rsi, \$rdx, \$rcx, \$r8
info symbol \$rcx
printf "  raw token object at param_ptr(rcx):\\n"
x/2gx \$rcx
set \$p = (unsigned long)\$rcx
set \$ok = 0
if \$p > 0x100000 && \$p < 0x00007fffffffffff
  set \$ok = 1
end
if \$ok
  set \$rep = (*(unsigned long*)\$p) & ~3ul
  printf "  paramName rep (masked) = 0x%lx\\n", \$rep
  info symbol \$rep
end
printf "  cachePath node handle = 0x%lx (0 == EMPTY)\\n", *(unsigned long*)\$rdx
finish
printf "  RETURN VtValue: rax(_info)=0x%lx rdx(_storage)=0x%lx\\n", \$rax, \$rdx
if \$rax == 0
  printf "  >>> RETURNED EMPTY VtValue (this is what triggers _FailGet)\\n"
else
  printf "  VtValue holds a value; storage word 0x%lx = rep if TfToken\\n", \$rdx
  info symbol \$rdx
end
printf "=== END ADAPTER ===\\n"
continue
end
break ${FAILGET_SYM}
commands
silent
printf "\\n=== HIT _FailGet ===\\n"
printf "  RDI = &this VtValue; raw object:\\n"
x/2gx \$rdi
printf "  frame 1 = hdMoonray::Light::Sync; disasm around call site:\\n"
frame 1
x/48i \$pc-0xc0
printf "=== END FAILGET ===\\n"
continue
end
run
EOF
    set +e
    timeout -k 15 1200 xvfb-run -a gdb -batch -x "/tmp/gdb-$tag.cmd" \
      > "$OUT/gdb-$tag.log" 2>&1
    status=$?
    set -e
    echo "$status" > "$OUT/gdb-$tag.exit"
    echo "exit=$status"
    echo "delegate hits:  $(grep -c '=== HIT UsdImagingDelegate' "$OUT/gdb-$tag.log" || true)"
    echo "SI adapter hits: $(grep -c '=== HIT HdSceneIndexAdapterSceneDelegate' "$OUT/gdb-$tag.log" || true)"
    echo "adapter hits:   $(grep -c '=== HIT UsdImagingPrimAdapter' "$OUT/gdb-$tag.log" || true)"
    echo "FailGet hits:   $(grep -c '=== HIT _FailGet' "$OUT/gdb-$tag.log" || true)"
    echo "empty returns:  $(grep -c 'RETURNED EMPTY VtValue' "$OUT/gdb-$tag.log" || true)"
    echo
  done
done
