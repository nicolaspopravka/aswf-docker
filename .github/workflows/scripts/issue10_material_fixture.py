import sys
from pxr import Usd, UsdGeom, UsdShade

stage = Usd.Stage.CreateNew(sys.argv[1])
sphere = UsdGeom.Sphere.Define(stage, '/Sphere')
material = UsdShade.Material.Define(stage, '/Material')
material.GetPrim().GetReferences().AddReference(
    '/asset/chess_set.usda', '/ChessSet/Chessboard/Materials/M_Chessboard')
UsdShade.MaterialBindingAPI.Apply(sphere.GetPrim()).Bind(material)
source = material.ComputeSurfaceSource('mtlx')
if not source[0]:
    raise RuntimeError('Referenced chessboard material has no surface shader')
print('Surface shader:', source[0].GetPath(), flush=True)
stage.GetRootLayer().Save()
