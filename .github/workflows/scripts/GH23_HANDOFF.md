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
  to 1/1/1/0. Exit 0. **v7.1 removes all `finish` and instead breaks at the
  adapter epilogue.**

## v7.1 probe (this commit)

- Entry breakpoints (delegate / SI adapter / prim adapter) now end with
  `continue` only.
- New breakpoint at `UsdImagingPrimAdapter::GetLightParamValue + 0x287`
  (= decimal +647, `add $0xa8,%rsp`; r12 = saved RDI = `&sret`, intact until
  popped at +659). Commands: decode r13 (`&paramName`, saved from r8 at +12),
  dump the 16-byte VtValue at `*(r12)`, TfToken-decode word 0, `continue`.
  Expect 46 epilogue hits (one per adapter call), all funnelling through the
  common +639..+661 epilogue.
- **Fallback if `break *(<sym>+0x287)` won't pend at parse time**: batch will
  abort with a clear gdb error in the log. Then either compute
  `set $epi=$pc+0x287` on the first entry hit and `tbreak *$epi` (captures only
  the first call), or break on `VtValue::_Move` (adapter+484) on the intensity
  path. The +0x287 offset was read from the v7 disasm (entry 0x7fffcf06cd30 ->
  add rsp at 0x7fffcf06cfb7 = +0x287).
- SI adapter epilogue intentionally NOT instrumented (its lightLink empty-return
  is already documented; keeping SI at entry-only keeps the log decodable).

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
