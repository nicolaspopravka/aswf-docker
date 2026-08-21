# Upstream PR hand-off: UpdateConnections diagnostics fix

Target: <https://projects.blender.org/blender/cycles> — branch `main`
Base revision validated: `1319002982e09970cb50f727e3f299cea78de229`
(current `main` tip = merge of PR #76; contains #75 + #76)

Patch file: `ci-cycles/cycles-updateconnections.patch` (single hunk,
`src/hydra/material.cpp`, +17/−4)
Validation: `.github/workflows/probe-cycles-updateconnections.yml` on this
branch (free GHA; builds `main@1319002` + patch, renders OpenChessSet and a
synthetic diagnostics scene, asserts the new warning strings).

## Why a new PR

PR #76 ("Hydra: Improve material input warnings", merged as `1319002`)
landed the `hasParameterMapping()` helper and the 3-case structure in
`UpdateParameters`. The locally validated 3-hunk patch was written against
v5.2.0, so its hunks 1+2 are already upstream and only the
`UpdateConnections` change remains. The old full patch no longer applies to
`main`; this single-hunk rebased patch does.

## What the change fixes

1. **Duplicated socket name in the warning.** The old message passed
   `dstSocketName` twice:

   ```cpp
   TF_WARN("Ignoring connection on '%s.%s', input '%s' was not found",
           nodePath.GetText(),
           dstSocketName.GetText(),
           dstSocketName.GetText());
   ```

   The third `%s` is labeled "input" but prints the USD socket name instead
   of `inputName` — the mapped Cycles-side name that was actually searched
   for and not found.

2. **No distinction between failure causes.** `UpdateParameters` (since #76)
   distinguishes three cases; `UpdateConnections` still printed one generic
   message. This mirrors that structure:
   - mapped USD node type + the USD input has a parameter mapping → "maps to
     unavailable Cycles input";
   - mapped USD node type without a mapping entry → "Unsupported USD input";
   - native Cycles node (`inputMapping == nullptr`) → "Could not find input"
     with the Cycles-side name.

Diagnostics-only: no connection behavior changes.

## Suggested commit message

```
Hydra: Fix UpdateConnections input-not-found diagnostics

The "input was not found" warning passed dstSocketName twice, printing
the USD socket name where the mapped Cycles input name belongs.

Align UpdateConnections with UpdateParameters' 3-case structure from
#76 so the warning distinguishes:
- USD inputs that map to an unavailable Cycles input,
- unsupported USD inputs with no mapping entry,
- missing inputs on native Cycles nodes.
```

## Suggested PR title

```
Hydra: Fix UpdateConnections input-not-found diagnostics
```

## Suggested PR description

```markdown
Follow-up to #76: bring `UpdateConnections` to the same 3-case diagnostic
structure that #76 added to `UpdateParameters`, and fix a small bug in the
existing warning.

**Bug**: the "input was not found" warning passes `dstSocketName` twice, so
the third `%s` (labeled `input '%s'`) prints the USD socket name instead of
`inputName` — the translated Cycles-side name that lookup actually failed
on. For mapped node types (e.g. UsdPreviewSurface) this reports the wrong
name whenever a mapped target does not exist on the Cycles node.

**Fix**: mirror #76's cases when an input is not found:
1. mapped node type, USD input has a parameter mapping → warn that it maps
   to an unavailable Cycles input;
2. mapped node type, no mapping entry → warn about an unsupported USD input;
3. native Cycles node → report the missing Cycles input by its real name.

Diagnostics only; connection behavior is unchanged.

Testing:
- Applies cleanly to `main` (`1319002`); built hdCycles against OpenUSD
  26.05 on the ASWF CY2027 stack and rendered OpenChessSet plus a synthetic
  scene exercising cases 2 and 3; asserted the new messages appear and the
  old duplicated-name message is gone.
- Case 1 additionally observed in production benchmark logs (ALab entry
  scene) with the equivalent v5.2.0-based patch.

AI assistance disclosure: this change was prepared with AI coding
assistance (OpenCode); the human author reviewed, validated, and takes
responsibility for the contribution, per the AI Contributions Policy.
```

## Filing checklist (Nicolas)

1. Re-run the probe workflow once before filing if `main` moved past
   `1319002` (workflow asserts the pinned revision; update pin + rebase if
   needed).
2. Push a branch containing the single commit (patch +
   suggested commit message above) to your Blender fork.
3. Open the PR against `blender/cycles` `main` with the title/description
   above; adjust the AI-disclosure wording to match what you used for
   #75/#76.
4. Reference it from benchmark GH #21 (UpdateParameters/material-translation
   context) after filing.
