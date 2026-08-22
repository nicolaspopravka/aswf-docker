#!/usr/bin/env python3

import argparse

from pxr import Gf, Usd, UsdGeom


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--geometry-count", type=int, default=12000)
    args = parser.parse_args()

    stage = Usd.Stage.CreateNew(args.output)
    world = UsdGeom.Xform.Define(stage, "/World")
    stage.SetDefaultPrim(world.GetPrim())
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    camera = UsdGeom.Camera.Define(stage, "/World/Camera")
    camera.AddTranslateOp().Set(Gf.Vec3d(0.0, 0.0, 5.0))

    for index in range(args.geometry_count):
        cube = UsdGeom.Cube.Define(stage, f"/World/Cube_{index:05d}")
        cube.AddTranslateOp().Set(Gf.Vec3d(10000.0 + index * 3.0, 0.0, 0.0))

    stage.GetRootLayer().Save()


if __name__ == "__main__":
    main()
