#!/usr/bin/env bash
# GH #23 gdb probe v5: dump the STATIC token objects (HdTokens->lightLink /
# shadowLink) that the callers pass as the 4th arg in RCX, plus libusd's own
# HdTokens->lightLink compare target in the adapter, plus static linkage
# evidence for the hdMoonray-vs-libusd TfToken ABI question.
#
# v4 established (all modes, both renderers, exit 0):
#   - SI adapter hits 92x (2 per light) in default, 0 in emu0 (toggle works)
#   - paramName reads {0x701, ...} / {0x3701|0x4401, ...} - masked ptrs
#     0x700/0x3700/0x4400 that are NOT valid addresses (no symbol matches)
#   - at _FailGet the VtValue is EMPTY (_info==0): {0,0,heap}
#   - caller disasm: Sync+1314 `mov 0x66857(%rip),%rax #0x7fff843c5ea0`,
#     +1321 `mov (%rax),%r14` (r14=HdTokens), +1353 `lea 0x38(%r14),%rcx`
#     (RCX=&HdTokens->lightLink as spurious 4th arg), +1357 call, while the
#     real paramName is RDX=r13=&stack-temp{0x701,0}
#   - rdlClassName caller uses a DIFFERENT static: RCX=0x7fff843c78a8
#     (=libhydramoonray data +0x698a8), i.e. a private token set, not the
#     shared HdTokens. So there are (at least) two HdTokens-like statics.
#
# v5 adds:
#   - dump x/2gx $rcx at delegate/SI hits: [RCX] = the static token object
#     (lightLink for Sync calls, shadowLink/private-set for rdlClassName),
#     answering: does the STATIC itself hold 0x701?
#   - dump x/16gx $rcx-0x40 at SI hits: the token-set region around the static
#   - adapter hit: disassemble the ADAPTER body (frame 0) to find libusd's
#     own HdTokens->lightLink load (the == compare target) and dump both rdx
#     and rcx content
#   - static linkage: ldd/readelf/nm/strings on libhydramoonray.so
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

echo "=== libhydramoonray linkage (TfToken ABI question) ==="
MOONRAY_SO=$(ls /opt/MoonRay/installs/openmoonray/lib64/libhydramoonray.so 2>/dev/null || find /opt/MoonRay -name "libhydramoonray.so" 2>/dev/null | head -1)
echo "MOONRAY_SO=$MOONRAY_SO"
if [ -n "${MOONRAY_SO:-}" ]; then
  echo "--- NEEDED (libs libhydramoonray links against) ---"
  readelf -d "$MOONRAY_SO" 2>/dev/null | grep NEEDED | sed 's/^/  /'
  echo "--- libtf/libusd deps referenced by libhydramoonray ---"
  ldd "$MOONRAY_SO" 2>/dev/null | grep -iE "usd|pxr|tf\.|tf-" | sed 's/^/  /' || true
  echo "--- pxr v0_25_5 symbol count in libhydramoonray ---"
  nm -D "$MOONRAY_SO" 2>/dev/null | grep -c "pxrInternal_v0_25_5" || echo 0
  echo "--- TfToken-related symbols (undefined = what it imports) ---"
  nm -D "$MOONRAY_SO" 2>/dev/null | grep "TfToken" | grep -i " U " | head -20 | sed 's/^/  /'
  echo "--- strings: lightLink/shadowLink/category in libhydramoonray ---"
  strings -a "$MOONRAY_SO" 2>/dev/null | grep -iE "^lightLink$|^shadowLink$|lightLink|shadowLink" | head -10 | sed 's/^/  /'
  echo "--- does libhydramoonray reference a TfTokenRegistry / _GetPtrImpl symbol? ---"
  nm -D "$MOONRAY_SO" 2>/dev/null | grep -iE "_GetPtrImpl|Tf_TokenRegistry|_RepPtrAndBits|TokenRegistry" | head -20 | sed 's/^/  /'
  echo "--- libtf.so copies present in image ---"
  find / -name "libtf.so*" 2>/dev/null | sed 's/^/  /'
fi
echo

# Body for the delegate + SI adapter breakpoints (2-arg members).
# RDI=this, RSI=&id, RDX=&paramName. RCX = caller's leftover 4th arg, which at
# the observed call sites is &HdTokens->lightLink / &private-token-set->member
# (the `lea 0x38(%r14),%rcx` from Sync) - i.e. the STATIC token object.
CAPTURE_BODY=$(cat <<'XEOF'
  printf "  REGS rdi=0x%lx rsi=0x%lx rdx=0x%lx rcx=0x%lx\n", $rdi, $rsi, $rdx, $rcx
  printf "  16 raw bytes at param_ptr(rdx):\n"
  x/2gx $rdx
  set $c = (unsigned long)$rcx
  set $cok = 0
  if $c > 0x100000 && $c < 0x00007fffffffffff
    set $cok = 1
  end
  if $cok
    printf "  [rcx] static token object at 0x%lx:\n", $c
    x/2gx $c
    set $clit = *(unsigned long*)$c
    printf "  [rcx] literal = 0x%lx  (masked ptr 0x%lx, bits 0x%lx)\n", $clit, $clit & ~3ul, $clit & 3ul
    if $clit == *(unsigned long*)$rdx
      printf "  [rcx] == [rdx] -> paramName IS the static token object\n"
    else
      printf "  [rcx] != [rdx] -> paramName is a DIFFERENT object/literal\n"
    end
    info symbol $c
    if $clit > 0x100000 && $clit < 0x00007fffffffffff
      info symbol $clit
    end
    printf "  token-set region around rcx-0x40:\n"
    x/16gx $rcx-0x40
  end
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
    echo "===== gdb delegate-param v5: mode=$mode renderer=$renderer ($tag) ====="
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
printf "  adapter entry disasm (frame 0) - looking for libusd HdTokens->lightLink compare:\\n"
x/24i \$pc
set \$d = (unsigned long)\$rdx
set \$dok = 0
if \$d > 0x100000 && \$d < 0x00007fffffffffff
  set \$dok = 1
end
if \$dok
  printf "  16 raw bytes at rdx (arg):\\n"
  x/2gx \$rdx
end
set \$c2 = (unsigned long)\$rcx
set \$c2ok = 0
if \$c2 > 0x100000 && \$c2 < 0x00007fffffffffff
  set \$c2ok = 1
end
if \$c2ok
  printf "  16 raw bytes at rcx (arg):\\n"
  x/2gx \$rcx
end
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
  printf "  paramName literal (rcx) = 0x%lx  (masked ptr 0x%lx, bits 0x%lx)\\n", \$lit, \$lit & ~3ul, \$lit & 3ul
  info symbol \$lit
  info symbol (\$lit & ~3ul)
end
set \$p2 = (unsigned long)\$rdx
set \$ok2 = 0
if \$p2 > 0x100000 && \$p2 < 0x00007fffffffffff
  set \$ok2 = 1
end
if \$ok2
  set \$lit2 = *(unsigned long*)\$p2
  printf "  rdx literal = 0x%lx  (masked ptr 0x%lx, bits 0x%lx)\\n", \$lit2, \$lit2 & ~3ul, \$lit2 & 3ul
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
