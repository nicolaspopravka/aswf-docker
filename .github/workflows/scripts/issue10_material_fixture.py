import os
import sys
from pxr import Sdf, Usd, UsdGeom, UsdShade

stage = Usd.Stage.CreateNew(sys.argv[1])
mesh = UsdGeom.Mesh.Define(stage, '/Surface')
mesh.CreatePointsAttr([(-1,-1,0), (1,-1,0), (1,1,0), (-1,1,0)])
mesh.CreateFaceVertexCountsAttr([4])
mesh.CreateFaceVertexIndicesAttr([0,1,2,3])
mesh.CreateSubdivisionSchemeAttr('none')
mesh.CreateNormalsAttr([(0,0,1)] * 4)
mesh.SetNormalsInterpolation('vertex')
UsdGeom.PrimvarsAPI(mesh).CreatePrimvar('st', Sdf.ValueTypeNames.TexCoord2fArray, 'faceVarying').Set([(0,0),(1,0),(1,1),(0,1)])
camera = UsdGeom.Camera.Define(stage, '/Camera')
camera.AddTranslateOp().Set((0,0,4))
material = UsdShade.Material.Define(stage, '/Material')
material.GetPrim().GetReferences().AddReference(
    '/asset/chess_set.usda', '/ChessSet/Chessboard/Materials/M_Chessboard')
UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material)
source = material.ComputeSurfaceSource('mtlx')
if not source[0]:
    raise RuntimeError('Referenced chessboard material has no surface shader')
print('Surface shader:', source[0].GetPath(), flush=True)
texture_count = 0
for prim in stage.Traverse():
    for attr in prim.GetAttributes():
        if attr.GetTypeName() == Sdf.ValueTypeNames.Asset:
            value = attr.Get()
            if value and value.path:
                print('Texture:', attr.GetPath(), value.path, value.resolvedPath, flush=True)
                if not value.resolvedPath or not os.path.isfile(value.resolvedPath):
                    raise RuntimeError('Texture did not resolve: ' + str(attr.GetPath()))
                texture_count += 1
if not texture_count:
    raise RuntimeError('No texture inputs found')
stage.GetRootLayer().Save()
