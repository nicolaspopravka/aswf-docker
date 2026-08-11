#!/usr/bin/env python3

import argparse

from pxr import Gf, Usd, UsdGeom, UsdLux, Vt


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    args = parser.parse_args()

    stage = Usd.Stage.CreateNew(args.output)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    world = UsdGeom.Xform.Define(stage, "/World")
    stage.SetDefaultPrim(world.GetPrim())

    camera = UsdGeom.Camera.Define(stage, "/World/Camera")
    camera.AddTranslateOp().Set(Gf.Vec3d(0.0, 0.0, 8.0))

    light = UsdLux.DistantLight.Define(stage, "/World/Light")
    light.CreateIntensityAttr(1000.0)
    light.CreateAngleAttr(1.0)

    prototype = UsdGeom.Cube.Define(stage, "/World/Prototypes/Cube")
    prototype.CreateSizeAttr(1.5)

    instancer = UsdGeom.PointInstancer.Define(stage, "/World/Instancer")
    instancer.CreatePrototypesRel().SetTargets([prototype.GetPath()])
    instancer.CreateProtoIndicesAttr(Vt.IntArray([0, 0]))
    instancer.CreatePositionsAttr(
        Vt.Vec3fArray([Gf.Vec3f(-1.0, 0.0, 0.0), Gf.Vec3f(1.0, 0.0, 0.0)])
    )
    instancer.CreateOrientationsAttr(
        Vt.QuathArray(
            [
                Gf.Quath(1.0, Gf.Vec3h(0.0, 0.0, 0.0)),
                Gf.Quath(0.7071068, Gf.Vec3h(0.0, 0.7071068, 0.0)),
            ]
        )
    )

    stage.GetRootLayer().Save()

    reopened = Usd.Stage.Open(args.output)
    orientations = UsdGeom.PointInstancer.Get(
        reopened, "/World/Instancer"
    ).GetOrientationsAttr()
    value = orientations.Get()
    assert str(orientations.GetTypeName()) == "quath[]", orientations.GetTypeName()
    assert isinstance(value, Vt.QuathArray), type(value)
    assert len(value) == 2
    print(f"stage={args.output}")
    print(f"orientations_type={orientations.GetTypeName()}")
    print(f"orientation_count={len(value)}")


if __name__ == "__main__":
    main()
