#!/usr/bin/env bash
# GH #23 gdb probe v2: attribute the empty VtValue reaching hdMoonray's
# Light::Sync (.Get<TfToken>() for lightLink/shadowLink) to a specific
# delegate/adapter implementation, in both default (scene-index emulation ON)
# and HD_ENABLE_SCENE_INDEX_EMULATION=0 modes.
#
# v1 failed arg decoding (RDX read as 0x710). This version is diagnostic-first:
# at each breakpoint it prints bt + full arg registers + entry disassembly so
# the true SysV ABI is visible, then ATTEMPTS a guarded TfToken decode (only
# when the register value looks like a pointer), so one bad read can't abort.
#
# Breaks on:
#   UsdImagingDelegate::GetLightParamValue              (classic delegate)
#   HdSceneIndexAdapterSceneDelegate::GetLightParamValue (scene-index adapter)
#   UsdImagingPrimAdapter::GetLightParamValue           (usdImaging adapter)
#   VtValue::_FailGet                                   (the failure point)
#
# TfToken (25.05): _rep = *(uint64*)&tok & ~3; std::string _str at offset 16
# in _Rep; string data ptr at *(char**)(rep+16). SdfPath: 8-byte node handle,
# 0 == empty path.
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

# DECODE helper text shared by the delegate + SI adapter breakpoints.
# Registers: RDI=this, RSI=&id, RDX=&paramName (SysV non-static member, 2 refs).
# We print registers + disasm first, then attempt guarded decode.
DECODE_BODY=$(cat <<'XEOF'
  bt 8
  printf "  REGS this(rdi)=0x%lx id_ptr(rsi)=0x%lx param_ptr(rdx)=0x%lx\n", $rdi, $rsi, $rdx
  x/8i $pc
  set $rdxok = 0
  if (unsigned long)$rdx > 0x100000 && (unsigned long)$rdx < 0x00007fffffffffff
    set $rdxok = 1
  end
  if $rdxok
    set $rep = (*(unsigned long*)$rdx) & ~3ul
    printf "  paramName rep=0x%lx\n", $rep
    if $rep > 0x100000 && $rep < 0x00007fffffffffff
      set $dptr = *(char**)((unsigned long)$rep + 16)
      if $dptr > 0x100000 && $dptr < 0x00007fffffffffff
        x/s $dptr
      else
        printf "  str data ptr 0x%lx invalid - skipping\n", $dptr
      end
    else
      printf "  paramName rep=0 (or invalid) - likely EMPTY TOKEN\n"
    end
  else
    printf "  paramName ptr 0x%lx not a valid pointer - skipping decode\n", $rdx
  end
  set $rsiok = 0
  if (unsigned long)$rsi > 0x100000 && (unsigned long)$rsi < 0x00007fffffffffff
    set $rsiok = 1
  end
  if $rsiok
    printf "  id node handle=0x%lx (0 == EMPTY path)\n", *(unsigned long*)$rsi
  else
    printf "  id ptr 0x%lx not valid - skipping decode\n", $rsi
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
    echo "===== gdb delegate-param v2: mode=$mode renderer=$renderer ($tag) ====="
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
${DECODE_BODY}
printf "=== END DELEGATE ===\\n"
continue
end
break ${SI_SYM}
commands
silent
printf "\\n=== HIT HdSceneIndexAdapterSceneDelegate::GetLightParamValue ===\\n"
${DECODE_BODY}
printf "=== END SI ADAPTER ===\\n"
continue
end
break ${ADAPTER_SYM}
commands
silent
printf "\\n=== HIT UsdImagingPrimAdapter::GetLightParamValue ===\\n"
bt 8
printf "  REGS this(rdi)=0x%lx prim_ptr(rsi)=0x%lx path_ptr(rdx)=0x%lx param_ptr(rcx)=0x%lx\n", \$rdi, \$rsi, \$rdx, \$rcx
x/8i \$pc
set \$rcxok = 0
if (unsigned long)\$rcx > 0x100000 && (unsigned long)\$rcx < 0x00007fffffffffff
  set \$rcxok = 1
end
if \$rcxok
  set \$rep = (*(unsigned long*)\$rcx) & ~3ul
  printf "  paramName rep=0x%lx\\n", \$rep
  if \$rep > 0x100000 && \$rep < 0x00007fffffffffff
    set \$dptr = *(char**)((unsigned long)\$rep + 16)
    if \$dptr > 0x100000 && \$dptr < 0x00007fffffffffff
      x/s \$dptr
    else
      printf "  str data ptr 0x%lx invalid - skipping\\n", \$dptr
    end
  else
    printf "  paramName rep=0 (or invalid) - likely EMPTY TOKEN\\n"
  end
else
  printf "  paramName ptr 0x%lx not a valid pointer - skipping decode\\n", \$rcx
end
set \$rdxok = 0
if (unsigned long)\$rdx > 0x100000 && (unsigned long)\$rdx < 0x00007fffffffffff
  set \$rdxok = 1
end
if \$rdxok
  printf "  cachePath node handle=0x%lx (0 == EMPTY)\\n", *(unsigned long*)\$rdx
else
  printf "  cachePath ptr 0x%lx not valid - skipping decode\\n", \$rdx
end
printf "=== END ADAPTER ===\\n"
continue
end
break ${FAILGET_SYM}
commands
silent
printf "\\n=== HIT _FailGet ===\\n"
bt 10
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
