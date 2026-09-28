"""Replace only the analytic sphere with a polygonal sphere for an A/B check."""

import math
import sys

from pxr import Gf, Usd, UsdGeom

stage = Usd.Stage.Open(sys.argv[1])
color = stage.GetPrimAtPath("/Sphere").GetAttribute("primvars:displayColor").Get()
stage.RemovePrim("/Sphere")
mesh = UsdGeom.Mesh.Define(stage, "/Sphere")
segments, rings = 32, 16
points = [Gf.Vec3f(0, 1, 0)]
for ring in range(1, rings):
    theta = math.pi * ring / rings
    for segment in range(segments):
        phi = 2 * math.pi * segment / segments
        points.append(
            Gf.Vec3f(
                math.sin(theta) * math.cos(phi),
                math.cos(theta),
                math.sin(theta) * math.sin(phi),
            )
        )
bottom = len(points)
points.append(Gf.Vec3f(0, -1, 0))
faces = []
for segment in range(segments):
    nxt = (segment + 1) % segments
    faces.append((0, 1 + nxt, 1 + segment))
    for ring in range(rings - 2):
        a, b = 1 + ring * segments + segment, 1 + ring * segments + nxt
        faces.append((a, b, b + segments, a + segments))
    a = 1 + (rings - 2) * segments
    faces.append((a + segment, a + nxt, bottom))
mesh.CreatePointsAttr(points)
mesh.CreateFaceVertexCountsAttr([len(face) for face in faces])
mesh.CreateFaceVertexIndicesAttr([index for face in faces for index in face])
mesh.CreateSubdivisionSchemeAttr("none")
mesh.CreateNormalsAttr(points)
mesh.SetNormalsInterpolation("vertex")
mesh.CreateDisplayColorAttr(color)
mesh.CreateExtentAttr([(-1, -1, -1), (1, 1, 1)])
assert len(points) == 482 and len(faces) == 512
stage.GetRootLayer().Export(sys.argv[2])
print("MESH_FIXTURE", len(points), "points", len(faces), "faces")
