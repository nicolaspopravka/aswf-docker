#!/usr/bin/env bash
# GH #23 gdb probe v7.3: adapter epilogue via ~UsdLuxLightAPI + saved paramName.
# (v7.1's `break *(<sym>+0x287)` address form FAILED to pend at parse time:
# "No symbol ... in current context" -> batch exit 1, run 31774485352.)
# (v7.2 run 31778768608: dtor breakpoint WORKS - dtor ret=0x7fffcf06cfb7 =
# adapter_lo+0x287 exactly; but r13 is CLOBBERED by +430 (lea 0x40(%rsp),%r13
# reuses it as a VtValue::_Move temp), so decoding r13 as paramName read
# garbage (rep=0x0 / 0x3000000002) and gdb died at "Cannot access memory at
# address 0x3000000018" -> .exit=1, batch killed before lightLink/shadowLink.)
#
# ABI PROVEN by v7 (run 31692448310, commit 95f8c74):
#   UsdImagingDelegate::GetLightParamValue(SdfPath const&, TfToken const&):
#     RDI=&sret, RSI=&this, RDX=&id(SdfPath), RCX=&paramName(TfToken)
#   HdSceneIndexAdapterSceneDelegate::GetLightParamValue(...): same 4-reg shape
#   UsdImagingPrimAdapter::GetLightParamValue(UsdPrim const&, SdfPath const&,
#     TfToken const&, UsdTimeCode) const:
#     RDI=&sret, RSI=&this(adapter), RDX=&usdPrim, RCX=&cachePath,
#     R8=&paramName(TfToken), R9=time
# v7 caller disasm (delegate+89..+147):
#   mov 0x0(%rbp),%rsi   adapter = _HdPrimInfo.adapter (shared_ptr 16B @+0)
#   lea 0x10(%rbp),%rdx  &usdPrim = _HdPrimInfo.usdPrim @+0x10
#   mov %r14,%rcx        &cachePath
#   mov %r13,%r8         &paramName
#   mov 0x4a0(%rbx),%r9  time
# v7 first-hit observation (intensity, emu0): usdPrim = {_type=0x1 (Prim,
# object.h enum UsdTypeObject=0, UsdTypePrim=1), _prim=0x2653230 (valid),
# _proxyPrimPath=0, _propName=0}; [rcx] cachePath=0x701; paramName decoded
# "intensity". So the adapter's `if (!light) return VtValue()` early-exit is
# REFUTED for this call and _IsCompatible() passed. The empty-FG paradox for
# shadowLink is still OPEN - it needs the adapter's RETURN VALUE captured.
#
# gdb lessons baked in:
#   - a resuming command (`finish`, `continue`, `step`, ...) inside a
#     breakpoint `commands` block makes gdb DISCARD the rest of that block
#     (v7 bug; collapsed counts to 1/1/1/0). No resuming commands anywhere.
#   - `break *(<addr-expr>)` does NOT pend when the symbol is only in a .so
#     loaded later (v7.1 failure). Only function-name location specs pend.
#
# v7.2 changes:
#   - drop the address-form epilogue breakpoint. NEW: break on the adapter's
#     epilogue via the pending-capable function symbol
#     UsdLuxLightAPI::~UsdLuxLightAPI (D1Ev/D0Ev): the v7 disasm shows the
#     adapter constructs UsdLuxLightAPI (primAdapter.cpp:725) and calls its
#     destructor at adapter+642, immediately before the common epilogue
#     `add $0xa8,%rsp` at +647. At the destructor entry (still in the adapter's
#     frame, pre-call) r12 = &sret (saved RDI) and r13 = &paramName are final.
#   - dump is gated on the destructor's return address ($rsp at entry = the
#     adapter's call-site, via the bound PLT jmp) falling inside
#     [$adapter_lo, $adapter_hi], which is captured on the first adapter entry
#     hit. Non-adapter ~UsdLuxLightAPI calls (e.g. the SI lightAPIAdapter) stay
#     silent. The exact D1Ev mangling is SELF-DISCOVERED at runtime via
#     `nm -D`/`nm` on the shipped libusd_usdLux.so (primary path), not guessed.
#   - v7.3: r13 is NOT &paramName at the dtor call (clobbered at +430 as a
#     VtValue::_Move temp). The paramName ADDRESS is captured at adapter entry
#     (from r8) into $v7pname and decoded in the epilogue instead. r12 = &sret
#     IS stable + final at +642: sret written by VtValue::_Move at +484 (attr
#     path) or the collection branches, and `mov %r12,%rax` at +654 is the
#     sret return. All paths converge at +639 -> dtor +642 -> epilogue +647.
#   - SI adapter entry-only (v6 behavior); its lightLink empty return is
#     already documented (no valueDs -> VtValue()).
#   - VtValue is 16 bytes in v25.05.01: {storage@0, typeInfo@8}; EMPTY iff
#     BOTH words are 0 (value.h). _FailGet dump is x/4gx.
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

# v7.2: self-discover the ~UsdLuxLightAPI D1Ev mangling from the shipped
# libusd_usdLux.so (primAdapter.cpp:725 constructs UsdLuxLightAPI; the v7
# disasm shows its dtor called at adapter+0x282, ret at +0x287). Prefer D1Ev
# (complete-object dtor, called for the stack-local); fall back to D0Ev.
LIGHT_DTOR_SYM=$({ nm -D /usr/local/lib/libusd_usdLux.so; nm /usr/local/lib/libusd_usdLux.so; } 2>/dev/null | \
  awk '/UsdLuxLightAPID1Ev/{print $3; exit}')
if [ -z "$LIGHT_DTOR_SYM" ]; then
  LIGHT_DTOR_SYM=$({ nm -D /usr/local/lib/libusd_usdLux.so; nm /usr/local/lib/libusd_usdLux.so; } 2>/dev/null | \
    awk '/UsdLuxLightAPID0Ev/{print $3; exit}')
fi
echo "--- ~UsdLuxLightAPI destructor symbol (v7.2 epilogue anchor) ---"
echo "  LIGHT_DTOR_SYM=$LIGHT_DTOR_SYM"

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

# gdb commands body for the v7.2 epilogue capture. Built AFTER DECODE_TOKEN
# (referenced below) as a bash var with an UNQUOTED heredoc so ${DECODE_TOKEN}
# expands here; gdb `$`-vars are escaped as \$ and gdb \n as \\n. Inserted into
# the outer heredoc via ${EPILOGUE_BLOCK} (inserted values are NOT re-scanned).
if [ -n "$LIGHT_DTOR_SYM" ]; then
EPILOGUE_BLOCK=$(cat <<EOF
break ${LIGHT_DTOR_SYM}
commands
silent
set \$dret = *(unsigned long*)\$rsp
if \$adapter_lo != 0 && \$dret >= \$adapter_lo && \$dret <= \$adapter_hi
  printf "\\n=== ADAPTER EPILOGUE via ~UsdLuxLightAPI (dtor ret=0x%lx, adapter lo=0x%lx hi=0x%lx, entry-count=%lu) ===\\n", \$dret, \$adapter_lo, \$adapter_hi, \$v6a
  if \$v7pname != 0
    set \$tokaddr = \$v7pname
    printf "  paramName (saved at entry from r8):\\n"
    ${DECODE_TOKEN}
  else
    printf "  (no saved paramName; \$v7pname==0)\\n"
  end
  set \$w0 = *(unsigned long*)\$r12
  set \$w1 = *(unsigned long*)(\$r12+8)
  printf "  sret VtValue 16B @0x%lx (r12): [0]=0x%lx [1]=0x%lx  => %s\\n", \$r12, \$w0, \$w1, (\$w0 == 0 && \$w1 == 0) ? "EMPTY VtValue" : "NON-EMPTY"
  if \$w0 != 0 || \$w1 != 0
    set \$tokaddr = \$r12
    printf "  attempt TfToken decode of storage word:\\n"
    ${DECODE_TOKEN}
  end
  printf "=== END ADAPTER EPILOGUE ===\\n"
end
continue
end
EOF
)
else
EPILOGUE_BLOCK="# LIGHT_DTOR_SYM unresolved via nm; epilogue capture SKIPPED"
fi

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
    echo "===== gdb delegate-param v7.3: mode=$mode renderer=$renderer ($tag) ====="
    cat > "/tmp/gdb-$tag.cmd" <<EOF
set pagination off
set confirm off
set breakpoint pending on
set print asm-demangle on
set \$v6d = 0
set \$v6s = 0
set \$v6a = 0
set \$v6f = 0
set \$adapter_lo = 0
set \$adapter_hi = 0
set \$v7pname = 0
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
printf "=== END SI ADAPTER ===\\n"
continue
end
break ${ADAPTER_SYM}
commands
silent
printf "\\n=== HIT UsdImagingPrimAdapter::GetLightParamValue (v7 ABI) ===\\n"
set \$isFirst = (\$v6a == 0)
set \$v6a = \$v6a + 1
printf "  REGS rdi(sret)=0x%lx rsi(this)=0x%lx rdx(&usdPrim)=0x%lx rcx(&cachePath)=0x%lx r8(&name)=0x%lx r9(time)=0x%lx\\n", \$rdi, \$rsi, \$rdx, \$rcx, \$r8, \$r9
set \$v7pname = (unsigned long)\$r8
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
  set \$adapter_lo = \$pc
  set \$adapter_hi = \$adapter_lo + 0x400
  printf "  v7.2: adapter range captured for ~UsdLuxLightAPI gate: lo=0x%lx hi=0x%lx\\n", \$adapter_lo, \$adapter_hi
end
printf "=== END ADAPTER ===\\n"
continue
end
${EPILOGUE_BLOCK}
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
