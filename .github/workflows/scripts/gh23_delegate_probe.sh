#!/usr/bin/env bash
# GH #23 gdb probe v4: identify the paramName token by disassembling the CALLER
# (Light::Sync) at every GetLightParamValue hit + the _FailGet call site.
#
# v3 showed the token object at param_ptr reads {0x701, heap_ptr} - 0x701 masks
# to a pointer (0x700) that is NOT a valid address, i.e. not a valid TfToken
# _Rep. Two possibilities: (a) ABI/token-encoding mismatch between hdMoonray
# and libusd, or (b) my register read is wrong.
#
# v4 (no `finish` - it terminates a batch command list):
#   - at each delegate/SI/adapter hit: print ALL arg regs, dump 16 raw bytes at
#     the paramName object, info-symbol the param ptr and rep, and disassemble
#     the caller frame (frame 1) around the call site to show the exact lea/mov
#     that supplied paramName (and thus its true address/encoding)
#   - at _FailGet: dump the empty VtValue (RDI) and disassemble a wide window of
#     Light::Sync around $pc (frame 1) to expose both GetLightParamValue calls
#     and the .Get<TfToken>() empty-checks
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

# Body for the delegate + SI adapter breakpoints (2-arg members).
# RDI=this, RSI=&id, RDX=&paramName.
CAPTURE_BODY=$(cat <<'XEOF'
  printf "  REGS rdi=0x%lx rsi=0x%lx rdx=0x%lx rcx=0x%lx\n", $rdi, $rsi, $rdx, $rcx
  printf "  16 raw bytes at param_ptr(rdx):\n"
  x/2gx $rdx
  printf "  frame 1 (caller) around call site:\n"
  frame 1
  x/16i $pc-0x40
  frame 0
  set $p = (unsigned long)$rdx
  set $ok = 0
  if $p > 0x100000 && $p < 0x00007fffffffffff
    set $ok = 1
  end
  if $ok
    set $lit = *(unsigned long*)$p
    printf "  paramName literal = 0x%lx  (masked ptr 0x%lx, bits 0x%lx)\n", $lit, $lit & ~3ul, $lit & 3ul
    info symbol $lit
    info symbol ($lit & ~3ul)
  end
  set $idok = 0
  if (unsigned long)$rsi > 0x100000 && (unsigned long)$rsi < 0x00007fffffffffff
    set $idok = 1
  end
  if $idok
    printf "  id node handle = 0x%lx (0 == EMPTY path)\n", *(unsigned long*)$rsi
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
    echo "===== gdb delegate-param v4: mode=$mode renderer=$renderer ($tag) ====="
    cat > "/tmp/gdb-$tag.cmd" <<EOF
set pagination off
set confirm off
set breakpoint pending on
set print asm-demangle on
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
printf "  16 raw bytes at param_ptr(rcx):\\n"
x/2gx \$rcx
printf "  frame 1 (caller) around call site:\\n"
frame 1
x/16i \$pc-0x40
frame 0
set \$p = (unsigned long)\$rcx
set \$ok = 0
if \$p > 0x100000 && \$p < 0x00007fffffffffff
  set \$ok = 1
end
if \$ok
  set \$lit = *(unsigned long*)\$p
  printf "  paramName literal = 0x%lx  (masked ptr 0x%lx, bits 0x%lx)\\n", \$lit, \$lit & ~3ul, \$lit & 3ul
  info symbol \$lit
  info symbol (\$lit & ~3ul)
end
printf "  cachePath node handle = 0x%lx (0 == EMPTY)\\n", *(unsigned long*)\$rdx
printf "=== END ADAPTER ===\\n"
continue
end
break ${FAILGET_SYM}
commands
silent
printf "\\n=== HIT _FailGet ===\\n"
printf "  empty VtValue object (RDI=&this):\\n"
x/3gx \$rdi
printf "  frame 1 = hdMoonray::Light::Sync; disasm around call site:\\n"
frame 1
x/80i \$pc-0x120
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
    echo
  done
done
