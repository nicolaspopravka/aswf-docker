# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
import faulthandler
import json
import sys

faulthandler.enable()
faulthandler.dump_traceback_later(60, repeat=True)
print('import-start', flush=True)
from pxr import Usd, UsdShade, Sdr
print('import-complete', Usd.GetVersion(), flush=True)

if sys.argv[1] == 'stage':
    print('stage-open-start', flush=True)
    stage = Usd.Stage.Open('/asset/chess_set.usda')
    if not stage:
        raise RuntimeError('Stage.Open failed')
    print('stage-open-complete', flush=True)
    materials = []
    shaders = []
    for prim in stage.Traverse():
        if prim.IsA(UsdShade.Material):
            material = UsdShade.Material(prim)
            materials.append({'path': str(prim.GetPath()), 'outputs': [
                {'name': output.GetFullName(), 'connections': [str(p) for p in output.GetRawConnectedSourcePaths()]}
                for output in material.GetOutputs()]})
        if prim.IsA(UsdShade.Shader):
            shaders.append(str(UsdShade.Shader(prim).GetIdAttr().Get()))
    print(json.dumps({'materials': materials, 'shaderIds': sorted(set(shaders)),
                      'shaderCount': len(shaders)}, indent=2), flush=True)
else:
    print('registry-start', flush=True)
    registry = Sdr.Registry()
    print('registry-created', flush=True)
    getter = getattr(registry, 'GetShaderNodeIdentifiers', None)
    if getter is None:
        getter = registry.GetNodeIdentifiers
    identifiers = list(getter())
    print('registry-identifiers', len(identifiers), flush=True)
    selected = [str(i) for i in identifiers if 'standard_surface' in str(i)]
    print(json.dumps(selected), flush=True)
print('probe-complete', flush=True)
faulthandler.cancel_dump_traceback_later()
