# Upstream PR hand-off: UpdateConnections diagnostics fix

Target: <https://projects.blender.org/blender/cycles> — branch `main`
Base revision validated: `1319002982e09970cb50f727e3f299cea78de229`
(current `main` tip = merge of PR #76; contains #75 + #76)

Patch file: `ci-cycles/cycles-updateconnections.patch` (single hunk,
`src/hydra/material.cpp`, +21/−4). Ready-to-file commit export:
`ci-cycles/0001-Hydra-Fix-UpdateConnections-input-not-found-diagnost.patch`
(git format-patch of commit `5690cdfda92382a689ee493f875b4c13fefd0c07`,
authored like the merged #75/#76 commits).
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
   of `inputName` — the translated Cycles-side name that was actually
   searched for and not found.

2. **No distinction between failure causes for mapped node types.**
   `UpdateParameters` (since #76) splits the two failure causes with distinct
   wording; `UpdateConnections` still printed one generic message. The change
   mirrors #76's nested structure and wording exactly:
   - mapped USD node type + the USD input has a parameter mapping → "maps to
     unavailable Cycles input '…' on '…'" (same sentence as
     `UpdateParameters`);
   - mapped USD node type without a mapping entry → "Unsupported USD input …
     ('…'); connection ignored" (same shape as `UpdateParameters`);
   - native Cycles node (`inputMapping == nullptr`) keeps the existing
     "Ignoring connection on …" sentence, now passing `inputName`.

Diagnostics-only: no connection behavior changes.

## Suggested commit message

```
Hydra: Fix UpdateConnections input-not-found diagnostics

The connection warning printed dstSocketName twice, reporting the USD
socket name where the translated Cycles input name belongs.

Align UpdateConnections with UpdateParameters' 3-case structure from
#76 so mapped USD node types now distinguish:
- USD inputs mapping to an unavailable Cycles input,
- unsupported USD inputs with no mapping entry,
with the same wording as UpdateParameters, and report the Cycles-side
name correctly. Native Cycles nodes keep their existing message.
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

**Fix**: mirror #76's nested case structure when an input is not found:
1. mapped node type, USD input has a parameter mapping → warn that it maps
   to an unavailable Cycles input (same wording as `UpdateParameters`,
   including the Cycles node name);
2. mapped node type, no mapping entry → warn about an unsupported USD input
   (same shape as `UpdateParameters`);
3. native Cycles node → keep the existing sentence, now reporting the
   Cycles-side input name.

For native Cycles nodes the reported name is unchanged in practice
(`inputName == dstSocketName` there); the visible improvements are on mapped
node types, which previously always printed the raw USD socket name twice.

Diagnostics only; connection behavior is unchanged.

Testing:
- Applies cleanly to `main` (`1319002`); built hdCycles against OpenUSD
  26.05 on the ASWF CY2027 stack and rendered OpenChessSet plus a synthetic
  scene exercising cases 2 and 3; asserted the new messages appear and the
  duplicated-name form of the warning is gone from the applied diff.
- Case 1 additionally observed in production benchmark logs (ALab entry
  scene) with the equivalent v5.2.0-based patch.

AI assistance disclosure: this change was prepared with AI coding
assistance (OpenCode); the human author reviewed, validated, and takes
responsibility for the contribution, per the AI Contributions Policy.
```

## Filing checklist (Nicolas)

Verified Aug 21, 2026: this machine has **no blender.org SSH key** and
**no fork** at `projects.blender.org/nicolaspopravka/cycles` — consistent
with how #75/#76 were filed (both merged commits authored
`Nicolas Popravka <nicolaspopravka@gmail.com>`, no fork to push to, i.e.
Gitea's attach-patch flow). Two filing paths:

**Path A — attach the patch (matches #75/#76 precedent):**
1. Re-run the probe workflow once before filing if `main` moved past
   `1319002` (workflow asserts the pinned revision; update pin + rebase if
   needed).
2. On projects.blender.org: `blender/cycles` → Pull Requests → New Pull
   Request → use "Attach patch files" with
   `ci-cycles/0001-Hydra-Fix-UpdateConnections-input-not-found-diagnost.patch`
   (git format-patch format; carries the commit message and authorship).
3. Set title + description from this document; adjust the AI-disclosure
   wording to match what you used for #75/#76.
4. Reference it from benchmark GH #21 after filing.

**Path B — fork push (DONE Aug 21, updated to `5690cdf`):** branch
`fix/hydra-updateconnections-diagnostics` is on the fork at exact
`5690cdfda92382a689ee493f875b4c13fefd0c07` (verified via HTTPS ls-remote;
amended from the earlier `50bac77` to adopt the #76-wording variant).
Push went through `ssh://git@git.blender.org/Nicolas-Popravka/cycles.git`
(`git.blender.org` is the reachable SSH hostname; projects.blender.org:22
was blocked from this network — Codex added the `Host git.blender.org`
block to `~/.ssh/config` using the same `id_ed25519_github` key). Only the
web-UI step remains:

Open <https://projects.blender.org/blender/cycles/compare/main...Nicolas-Popravka:fix/hydra-updateconnections-diagnostics>
with title/description from this document.

If the temp clone was cleaned before pushing, recreate it from a fresh
clone + `git am` of
`ci-cycles/0001-Hydra-Fix-UpdateConnections-input-not-found-diagnost.patch`
onto `1319002982e09970cb50f727e3f299cea78de229`, then add a remote
`blender-fork ssh://git@git.blender.org/Nicolas-Popravka/cycles.git`.
