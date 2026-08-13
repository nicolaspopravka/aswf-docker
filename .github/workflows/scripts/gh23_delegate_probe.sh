#!/usr/bin/env bash
# GH #23 gdb probe v7: adapter return-value capture via `finish` + ABI fix.
#
# v6 (commit 6bf3265, run 31687455742, exit 0) decoded and REVEALED that the
# v6 ABI header was still WRONG for the prim adapter. Correct x86-64 SysV ABI
# (VtValue returned via hidden sret), verified from the delegate's call-site
# disasm (lea 0x10(%rbp) = &_HdPrimInfo.usdPrim; usdPrim@+0x10 because
# UsdImagingPrimAdapterSharedPtr = std::shared_ptr = 16 bytes):
#   UsdImagingDelegate::GetLightParamValue(SdfPath const&, TfToken const&):
#     RDI=&sret, RSI=&this, RDX=&id(SdfPath), RCX=&paramName(TfToken)
#   HdSceneIndexAdapterSceneDelegate::GetLightParamValue(...): same 4-reg shape
#   UsdImagingPrimAdapter::GetLightParamValue(UsdPrim const&, SdfPath const&,
#     TfToken const&, UsdTimeCode) const:
#     RDI=&sret, RSI=&this(adapter), RDX=&usdPrim, RCX=&cachePath,
#     R8=&paramName(TfToken), R9=time  (v6 printed "rsi=&prim rdx=&cachePath
#     rcx=&name r8=time" = everything shifted by one; R8 really = &paramName)
#
# v6 new facts baked into v7:
#   - VtValue in v25.05.01 is 16 bytes: {storage(8), typeInfo(8)} (value.h:
#     _MaxLocalSize = sizeof(void*); comment "total structure 16 bytes").
#     A VtValue is EMPTY iff BOTH words are 0. So the _FailGet object at
#     0x7fffffffc150 ({0,0}, [0x160]=0x3818688 is the NEXT stack slot) really
#     is empty - the coding error text ("from empty VtValue", value.cpp:501)
#     is ground truth.
#   - usdPrim member layout (object.h): UsdObject = {UsdObjType _type@0,
#     Usd_PrimDataHandle _prim@8, SdfPath _proxyPrimPath@0x10, TfToken
#     _propName@0x18} (32 bytes). [RDX]=0x1 is UsdObjType::Prim (enum object.h:
#     UsdTypeObject=0, UsdTypePrim=1), NOT "cachePath=0x1" as v6 labeled.
#     cachePath is really [RCX]=0x701 = the delegate's id (identity convert).
#   - emu0 FG#1 chain: delegate("shadowLink", sret=0x7fffffffc150) ->
#     adapter(same sret) -> the returned VtValue at sret is empty at the FG.
#     The adapter's source (primAdapter.cpp) returns non-empty
#     VtValue(GetIdForCollection(...)) for lightLink/shadowLink, so emptiness
#     means either the `if (!light) return VtValue()` path (usdPrim._prim
#     null or _IsCompatible() false) or the fallback. v6 never captured the
#     adapter's RETURN VALUE - that is v7's core job.
#   - FG call site (Light::Sync+335): `mov -0x78(%rbp),%rax; test; je +1968;
#     and $~7,%rcx; cmpl $0xd,0x10(%rcx); je +1560` = inline IsHolding<TfToken>
#     with the empty path sharing the _FailGet@plt call at +522 (return +527).
#
# v7 actions:
#   - prim adapter: corrected REGS printout, usdPrim field dump (_type/_prim/
#     _proxyPrimPath/_propName), cachePath from [RCX], paramName from [R8],
#     `finish` to capture the sret VtValue (16B) + TfToken decode of storage
#   - SI adapter: `finish` + sret dump too, with a $v7depth counter (the 1st
#     hit per param forwards and re-enters -> depth 1..2; the 2nd hit's dump
#     proves the empty return). Interleaved HIT markers are decodable by depth.
#   - _FailGet: widen dump to 4x8B; note the 16-byte VtValue layout.
#   - keeps range guards; entry prologue + caller disasm once per function.
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

# Decode the TfToken whose ADDRESS is in $tokaddr. Reads the 8-byte token
# value (= _RepPtrAndBits), then the _Rep object: _str std::string at +16
# (_M_p at +16, _M_len at +24). All reads range-guarded.
# Single-quoted on purpose: the body must reach gdb with literal $tokaddr etc.
DECODE_TOKEN='  set $tokrep = *(unsigned long*)$tokaddr
  set $tokp = $tokrep & ~3ul
  printf "      TfToken@0x%lx: rep=0x%lx  masked=0x%lx  bits=0x%lx\n", $tokaddr, $tokrep, $tokp, $tokrep & 3ul
  set $tokok = 0
  if $tokrep > 0x100000 && $tokp > 0x100000 && $tokp < 0x00007fffffffffff
    set $tokok = 1
  end
  if $tokok
    set $toklen = *(unsigned long*)($tokp + 24)
    set $tokmp = *(unsigned long*)($tokp + 16)
    printf "      _Rep+16 (_M_p)=0x%lx  _Rep+24 (_M_len)=%lu\n", $tokmp, $toklen
    set $tokmok = 0
    if $tokmp > 0x100000 && $tokmp < 0x00007fffffffffff && $toklen > 0 && $toklen < 256
      set $tokmok = 1
    end
    if $tokmok
      printf "      string: "
      x/s $tokmp
    else
      printf "      (string unreadable: len=%lu mp=0x%lx)\n", $toklen, $tokmp
    end
  else
    printf "      (rep not a valid pointer)\n"
  end'

# Body for the delegate + SI adapter breakpoints (2-arg members, VtValue sret).
# RDI=&sret-result, RSI=&this, RDX=&id(SdfPath), RCX=&paramName(TfToken).
# The TfToken decode is INLINED (twice) rather than injected via a variable:
# bash word-splits a bare $VAR on newlines and would re-expand $ inside
# "$VAR", so nesting the decode block would corrupt it. All $ stay literal
# inside this single-quoted heredoc.
# __CTR__ = per-breakpoint counter convenience variable name (substituted by
# bash) so each function's prologue/caller disasm prints exactly once.
CAPTURE_BODY=$(cat <<'XEOF'
  set $isFirst = (__CTR__ == 0)
  set __CTR__ = __CTR__ + 1
  printf "  REGS rdi(sret)=0x%lx rsi(this)=0x%lx rdx(&id)=0x%lx rcx(&name)=0x%lx\n", $rdi, $rsi, $rdx, $rcx
  set $idv = *(unsigned long*)$rdx
  printf "  [rdx] SdfPath = 0x%lx  (primPart=%lu propPart=%lu%s)\n", $idv, $idv & 0xffffffff, ($idv >> 32) & 0xffffffff, ($idv & 0xffffffff) == 0 ? "  [EMPTY PATH]" : ""
  set $tokaddr = (unsigned long)$rcx
  printf "  decode [rcx] as paramName:\n"
  set $tokrep = *(unsigned long*)$tokaddr
  set $tokp = $tokrep & ~3ul
  printf "      TfToken@0x%lx: rep=0x%lx  masked=0x%lx  bits=0x%lx\n", $tokaddr, $tokrep, $tokp, $tokrep & 3ul
  set $tokok = 0
  if $tokrep > 0x100000 && $tokp > 0x100000 && $tokp < 0x00007fffffffffff
    set $tokok = 1
  end
  if $tokok
    set $toklen = *(unsigned long*)($tokp + 24)
    set $tokmp = *(unsigned long*)($tokp + 16)
    printf "      _Rep+16 (_M_p)=0x%lx  _Rep+24 (_M_len)=%lu\n", $tokmp, $toklen
    set $tokmok = 0
    if $tokmp > 0x100000 && $tokmp < 0x00007fffffffffff && $toklen > 0 && $toklen < 256
      set $tokmok = 1
    end
    if $tokmok
      printf "      string: "
      x/s $tokmp
    else
      printf "      (string unreadable: len=%lu mp=0x%lx)\n", $toklen, $tokmp
    end
  else
    printf "      (rep not a valid pointer)\n"
  end
  set $tokaddr = (unsigned long)$rdx
  printf "  decode [rdx] as TfToken (id reinterpreted; expect string==path only if this is really a token):\n"
  set $tokrep = *(unsigned long*)$tokaddr
  set $tokp = $tokrep & ~3ul
  printf "      TfToken@0x%lx: rep=0x%lx  masked=0x%lx  bits=0x%lx\n", $tokaddr, $tokrep, $tokp, $tokrep & 3ul
  set $tokok = 0
  if $tokrep > 0x100000 && $tokp > 0x100000 && $tokp < 0x00007fffffffffff
    set $tokok = 1
  end
  if $tokok
    set $toklen = *(unsigned long*)($tokp + 24)
    set $tokmp = *(unsigned long*)($tokp + 16)
    printf "      _Rep+16 (_M_p)=0x%lx  _Rep+24 (_M_len)=%lu\n", $tokmp, $toklen
    set $tokmok = 0
    if $tokmp > 0x100000 && $tokmp < 0x00007fffffffffff && $toklen > 0 && $toklen < 256
      set $tokmok = 1
    end
    if $tokmok
      printf "      string: "
      x/s $tokmp
    else
      printf "      (string unreadable: len=%lu mp=0x%lx)\n", $toklen, $tokmp
    end
  else
    printf "      (rep not a valid pointer)\n"
  end
  if $isFirst
    printf "  entry prologue (frame 0):\n"
    x/40i $pc
    printf "  caller (frame 1) around call site:\n"
    frame 1
    x/24i $pc-0x40
    frame 0
  end
  if (unsigned long)$rsi > 0x100000 && (unsigned long)$rsi < 0x00007fffffffffff
    printf "  this=0x%lx vtable=0x%lx\n", $rsi, *(unsigned long*)$rsi
  end
XEOF
)

# Same body but with per-breakpoint counter variables substituted.
CAPTURE_DELEGATE=${CAPTURE_BODY//__CTR__/\$v6d}
CAPTURE_SI=${CAPTURE_BODY//__CTR__/\$v6s}

for mode in default emu0; do
  if [ "$mode" = emu0 ]; then
    export HD_ENABLE_SCENE_INDEX_EMULATION=0
  else
    unset HD_ENABLE_SCENE_INDEX_EMULATION
  fi

  for renderer in "Moonray" "Moonray (debug)"; do
    tag=$(echo "$mode-$renderer" | tr ' ()' '___')
    echo "===== gdb delegate-param v7: mode=$mode renderer=$renderer ($tag) ====="
    cat > "/tmp/gdb-$tag.cmd" <<EOF
set pagination off
set confirm off
set breakpoint pending on
set print asm-demangle on
set \$v6d = 0
set \$v6s = 0
set \$v6a = 0
set \$v6f = 0
set \$v7depth = 0
file ${python3_bin}
set args ${script_bin} --renderer "${renderer}" --camera /World/Camera --imageWidth 256 ${SCENE} ${OUT}/minimal-${tag}.exr
break ${DELEGATE_SYM}
commands
silent
printf "\\n=== HIT UsdImagingDelegate::GetLightParamValue ===\\n"
${CAPTURE_DELEGATE}
printf "=== END DELEGATE ===\\n"
continue
end
break ${SI_SYM}
commands
silent
printf "\\n=== HIT HdSceneIndexAdapterSceneDelegate::GetLightParamValue ===\\n"
${CAPTURE_SI}
set \$v7depth = \$v7depth + 1
set \$v7sret = (unsigned long)\$rdi
printf "  --- v7: finishing SI adapter (depth=%d, sret=0x%lx) ---\\n", \$v7depth, \$v7sret
finish
set \$w0 = *(unsigned long*)\$v7sret
set \$w1 = *(unsigned long*)(\$v7sret+8)
printf "  POST-RETURN sret VtValue 16B @0x%lx: [0]=0x%lx [1]=0x%lx  => %s\\n", \$v7sret, \$w0, \$w1, (\$w0 == 0 && \$w1 == 0) ? "EMPTY VtValue" : "NON-EMPTY"
if \$w0 != 0 || \$w1 != 0
  set \$tokaddr = \$v7sret
  printf "  attempt TfToken decode of storage word:\\n"
  ${DECODE_TOKEN}
end
set \$v7depth = \$v7depth - 1
printf "=== END SI ADAPTER ===\\n"
continue
end
break ${ADAPTER_SYM}
commands
silent
printf "\\n=== HIT UsdImagingPrimAdapter::GetLightParamValue (v7 ABI) ===\\n"
set \$isFirst = (\$v6a == 0)
set \$v6a = \$v6a + 1
set \$v7sret = (unsigned long)\$rdi
printf "  REGS rdi(sret)=0x%lx rsi(this)=0x%lx rdx(&usdPrim)=0x%lx rcx(&cachePath)=0x%lx r8(&name)=0x%lx r9(time)=0x%lx\\n", \$rdi, \$rsi, \$rdx, \$rcx, \$r8, \$r9
printf "  [rdx] usdPrim: _type=0x%lx (0=obj 1=prim 2=prop 3=attr 4=rel) _prim=0x%lx _proxyPrimPath=0x%lx _propName=0x%lx\\n", *(unsigned long*)\$rdx, *(unsigned long*)(\$rdx+8), *(unsigned long*)(\$rdx+16), *(unsigned long*)(\$rdx+24)
set \$cpv = *(unsigned long*)\$rcx
printf "  [rcx] cachePath SdfPath = 0x%lx  (primPart=%lu propPart=%lu%s)\\n", \$cpv, \$cpv & 0xffffffff, (\$cpv >> 32) & 0xffffffff, (\$cpv & 0xffffffff) == 0 ? "  [EMPTY PATH]" : ""
set \$tokaddr = (unsigned long)\$r8
printf "  decode [r8] as paramName:\\n"
${DECODE_TOKEN}
if \$isFirst
  printf "  entry prologue (frame 0):\\n"
  x/40i \$pc
  printf "  adapter later code incl. return/empty paths (\$pc+0x150 .. \$pc+0x400):\\n"
  x/80i \$pc+0x150
  printf "  caller (frame 1) around call site:\\n"
  frame 1
  x/24i \$pc-0x40
  frame 0
end
printf "  --- v7: finish adapter to capture return at sret 0x%lx ---\\n", \$v7sret
finish
set \$w0 = *(unsigned long*)\$v7sret
set \$w1 = *(unsigned long*)(\$v7sret+8)
printf "  POST-RETURN sret VtValue 16B @0x%lx: [0]=0x%lx [1]=0x%lx  => %s\\n", \$v7sret, \$w0, \$w1, (\$w0 == 0 && \$w1 == 0) ? "EMPTY VtValue" : "NON-EMPTY"
if \$w0 != 0 || \$w1 != 0
  set \$tokaddr = \$v7sret
  printf "  attempt TfToken decode of storage word:\\n"
  ${DECODE_TOKEN}
end
printf "=== END ADAPTER ===\\n"
continue
end
break ${FAILGET_SYM}
commands
silent
printf "\\n=== HIT _FailGet ===\\n"
set \$v6f = \$v6f + 1
printf "  empty VtValue object (RDI=&this; 16B layout: storage@0, typeInfo@8; empty iff both 0):\\n"
x/4gx \$rdi
printf "  backtrace:\\n"
bt 4
printf "  frame 1 (hdMoonray::Light::Sync) callee-saved regs hold query state; decode:\\n"
set \$tokaddr = (unsigned long)\$r13
printf "  [r13] as TfToken (candidate &id temp):\\n"
${DECODE_TOKEN}
set \$tokaddr = (unsigned long)\$r14 + 0x38
printf "  [r14+0x38] as TfToken (candidate HdTokens->lightLink):\\n"
${DECODE_TOKEN}
set \$tokaddr = (unsigned long)\$r14 + 0x168
printf "  [r14+0x168] as TfToken (candidate shadowLink/other):\\n"
${DECODE_TOKEN}
set \$tokaddr = (unsigned long)\$r14 + 0x160
printf "  [r14+0x160] as TfToken (candidate neighbor):\\n"
${DECODE_TOKEN}
printf "  frame 1 = hdMoonray::Light::Sync; disasm around call site:\\n"
frame 1
x/80i \$pc-0x120
frame 0
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
