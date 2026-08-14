# GH #23 Handoff — OpenCode -> next agent (Aug 14, 2026)

Issue re-assigned from OpenCode to Codex. This file is the pickup point. The
probe branch is `opencode/gh23-minimal-cross-delegate` (remote:
`github.com-nicolas-aswf-fork:nicolaspopravka/aswf-docker.git`). Pushing to it
auto-dispatches the free CPU-only GHA probe.

## Issue

`VtValue::_FailGet` ("Attempted to get value of type 'TfToken' from empty
VtValue.") fires inside `hdMoonray::Light::Sync` when reading `HdTokens->lightLink`
/ `shadowLink` via `.Get<TfToken>()` on the returned light-param value. Two
modes behave differently:

- **default (HD_ENABLE_SCENE_INDEX_EMULATION on)**: root cause identified —
  `Hd_DataSourceLight::Get` (lightAPIAdapter.cpp) omits lightLink/shadowLink;
  `HdSceneIndexAdapterSceneDelegate::GetLightParamValue`
  (sceneIndexAdapterSceneDelegate.cpp:1466-1489) returns `VtValue()` when no
  `valueDs`; no collection scene index exists in the stack; only the legacy
  `lightAdapter.cpp` populates via `UsdImagingTokens->collectionln` /
  `collectionShadowLink`.
- **emu0 (HD_ENABLE_SCENE_INDEX_EMULATION=0, pure legacy)**: PARADOX OPEN. Per
  v25.05.01 source, `UsdImagingPrimAdapter::GetLightParamValue` (primAdapter.cpp
  :747-756) returns a NON-empty `VtValue(collectionCache.GetIdForCollection(...))`
  for lightLink/shadowLink, yet the emu0 `_FailGet` backtrace shows the
  delegate->adapter chain handed `Light::Sync` an empty VtValue for shadowLink.

## Proven (v6 + v7 probes, all exit 0)

- **ABI (x86-64 SysV, VtValue by hidden sret)** — confirmed by reg dumps +
  caller disasm, not guesses:
  - `UsdImagingDelegate::GetLightParamValue`: `RDI=&sret, RSI=&this,
    RDX=&id(SdfPath), RCX=&paramName`.
  - `HdSceneIndexAdapterSceneDelegate::GetLightParamValue`: same 4-reg shape.
  - `UsdImagingPrimAdapter::GetLightParamValue`: `RDI=&sret, RSI=&this(adapter),
    RDX=&usdPrim, RCX=&cachePath, R8=&paramName, R9=time`. (Earlier probe
    headers were off-by-one; `paramName` is in R8.)
- **usdPrim layout** (`_HdPrimInfo` = `{adapter shared_ptr@0, usdPrim@0x10}`, so
  delegate `lea 0x10(%rbp),%rdx` = `&usdPrim`). `UsdObject` = `{_type@0,
  _prim@8, _proxyPrimPath@0x10, _propName@0x18}`. v7 hit: `_type=0x1` (Prim),
  `_prim` valid -> the adapter's `if (!light) return VtValue()` early-exit is
  refuted for the intensity hit; `_IsCompatible()` passed.
- **VtValue is 16 bytes in v25.05.01**: `{storage@0, typeInfo@8}`; EMPTY iff
  both words are 0. The `_FailGet` object really is empty.
- **The v7 `finish` bug**: a resuming command (`finish`/`continue`/`step`/...)
  inside a breakpoint `commands` block makes gdb DISCARD the rest of that block
  (incl. the trailing `continue`). v7 (commit 95f8c74, run 31692448310) therefore
  captured only the first param (intensity) per breakpoint; hit counts collapsed
  to 1/1/1/0. Exit 0.
- **Address-form breakpoints don't pend** (v7.1 lesson): `break *(<sym>+0x287)`
  is NOT a pending-capable location spec. When the symbol only exists in a .so
  loaded later, gdb fails at parse time with `No symbol "...GetLightParamValue..."
  in current context` (batch exit 1). **Only function-name location specs pend.**

## v7.1 probe (commit 8392922, run 31774485352) — FAILED, replaced by v7.2

- Entry breakpoints (delegate / SI adapter / prim adapter) end with `continue`
  only. **This part survived into v7.2.**
- The new epilogue breakpoint used `break *(${ADAPTER_SYM}+0x287)` — the
  address form above. Result: all 4 `.exit` files = 1, zero hits, gdb error
  `Error in sourced command file: /tmp/gdb-emu0-Moonray.cmd:211: No symbol
  "...GetLightParamValue..." in current context.` Do NOT reuse the address form.

## v7.3 probe (current commit) — epilogue via ~UsdLuxLightAPI + saved paramName

- Same entry breakpoints as v7.1 (`continue` only). On EVERY prim adapter entry
  hit: `$v7pname = (unsigned long)$r8` (the paramName TfToken address, saved
  for the epilogue block). On the FIRST entry: `$adapter_lo = $pc`,
  `$adapter_hi = $adapter_lo + 0x400`.
- NEW epilogue breakpoint on the PENDING-CAPABLE function symbol
  `UsdLuxLightAPI::~UsdLuxLightAPI` (D1Ev preferred, D0Ev fallback). v7.2 run
  (commit d305ffd, run 31778768608) PROVED it works: dtor ret = `$adapter_lo +
  0x287` (0x7fffcf06cfb7), the adapter's call-site, exactly as the v7 disasm
  predicted. The destructor is called at adapter+642, epilogue `add $0xa8,%rsp`
  at +647, `mov %r12,%rax` (sret) at +654.
- The dump is GATED on `$dret = *(unsigned long*)$rsp` inside
  `[$adapter_lo, $adapter_hi]` — non-adapter ~UsdLuxLightAPI calls stay silent.
- **v7.2 DISCOVERY — r13 is clobbered by +642**: `lea 0x40(%rsp),%r13` at
  adapter+430 reuses r13 as a `VtValue::_Move` source temp, so the epilogue's
  r13-as-paramName decode read garbage (`rep=0x0` then `0x3000000002`) and gdb
  aborted on `Cannot access memory at address 0x3000000018` (guard
  `0x3000000000 < 0x7fffffffffff` passes) → all 4 `.exit`=1, batch killed
  before the lightLink/shadowLink calls. **Fix (v7.3): decode `$v7pname`
  (saved from r8 at entry) instead of r13.**
- **r12 = &sret is stable and final at dtor entry**: the sret is written by
  `VtValue::_Move` at +484 (attr path; the source temp is filled by the
  virtual call at +520) or by the collection branches (lightLink/shadowLink);
  all paths converge at +639 → dtor +642 → epilogue +647 → `mov %r12,%rax`
  +654. So the 16-byte sret dump at `*(r12)` IS the returned value.
- The D1Ev mangling is SELF-DISCOVERED at runtime via `nm -D`/`nm` on the
  shipped `/usr/local/lib/libusd_usdLux.so`; if neither D1 nor D0 resolves,
  the probe prints `LIGHT_DTOR_SYM=... SKIPPED` and still captures all entry
  data. Expect one epilogue hit per adapter call. `_FailGet` dump unchanged
  (`x/4gx`).

## To run / pick up

```bash
cd ~/Projects/aswf-docker-codex        # clone of the fork
git checkout opencode/gh23-minimal-cross-delegate
# push any new commit -> workflow gh23-delegate-param.yml runs free on GHA
gh run list --workflow gh23-delegate-param.yml
gh run download <RUN_ID> -R nicolaspopravka/aswf-docker
# artifacts: gdb-{default,emu0}-Moonray{,__debug_}.log under gh23-delegate-param/
```

## Analysis plan for the epilogue output

1. In `gdb-emu0-Moonray.log`, find the `=== ADAPTER EPILOGUE ===` whose
   paramName decode reads `shadowLink` (param 46 of 46) and check the sret
   dump: EMPTY vs NON-EMPTY.
   - NON-EMPTY TfToken -> the adapter returned a value; the emptiness seen by
     `Light::Sync` came from the DELEGATE layer (identity convert / sret reuse),
     i.e. the paradox shifts one level up and the delegate's return path
     (delegate+147..+168 disasm) becomes the next capture target.
   - EMPTY -> the adapter's shadowLink branch (primAdapter.cpp:754-756) did not
     return `VtValue(GetIdForCollection(...))`; check which branch ran (the
     `GetIdForCollection`/collection-cache path vs a fallthrough) and whether
     `light.GetShadowLinkCollectionAPI()` is the problem.
2. Repeat for `lightLink` (param 45). Cross-check the default-mode log for the
   same params (SI active) to confirm SI-vs-legacy divergence.
3. `_FailGet` hits in emu0 should still fire for shadowLink/lightLink; if they
   do while the epilogue shows NON-EMPTY, the value is lost between the adapter
   epilogue and `Light::Sync`'s `.Get<TfToken>()` — inspect the delegate's
   return (`mov -0x78(%rbp)` reuse of the FG's `this`).

## Where things live

- Probe: `.github/workflows/scripts/gh23_delegate_probe.sh`
  (self-contained; header lines 1-52 are the running notebook).
- Workflow: `.github/workflows/gh23-delegate-param.yml`
  (`CANDIDATE_IMAGE` = openmoonray-hydra `sha256:952bf3...` = MoonRay
  v2026.29.1 + OpenUSD 25.05.01).
- Repro scene: `ci-moonray-hydra/minimal.usda` (`DistantLight "Key"`).
- OpenUSD 25.05.01 source (local, matched to the image build):
  - `/Users/nicolas/Projects/USD/pxr/usdImaging/usdImaging/primAdapter.cpp:718-782`
  - `.../lightAdapter.cpp`, `.../lightAPIAdapter.cpp:67`,
    `.../delegate.cpp:3019-3035`, `.../delegate.h:635-646`
  - `/Users/nicolas/Projects/USD/pxr/imaging/hd/sceneIndexAdapterSceneDelegate.cpp:1466-1489`
  - `/Users/nicolas/Projects/USD/pxr/usd/usd/object.h:34-46,730-731`
  - `/Users/nicolas/Projects/USD/pxr/base/vt/value.h:146-181`
- v7 artifacts (for reference): `/private/tmp/gh23-v7/gh23-delegate-param/`
  (download of run 31692448310).
- v7.1 artifacts (failed run): `/private/tmp/gh23-v71/gh23-delegate-param/`
  (download of run 31774485352 — `.exit` = 1, zero hits, cmd line 211
  "No symbol ... in current context").
- v7.2 artifacts (run 31778768608): `/private/tmp/gh23-v72/gh23-delegate-param/`
  — dtor breakpoint works (ret=lo+0x287), but r13 clobbered → gdb crash at
  `0x3000000018`, `.exit`=1, 5-6 hits/mode, FailGet never reached. Disasm of
  adapter +336..+661 (incl. the `_Move`/collection branch structure) is in
  `gdb-emu0-Moonray.log` lines ~179-270.
