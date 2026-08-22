#!/usr/bin/env python3

import argparse
import gc
import json
import time

from pxr import Usd, UsdAppUtils, UsdGeom


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scene")
    parser.add_argument("image")
    parser.add_argument("result")
    args = parser.parse_args()

    stage = Usd.Stage.Open(args.scene)
    camera = UsdGeom.Camera(stage.GetPrimAtPath("/World/Camera"))
    recorder = UsdAppUtils.FrameRecorder("HdCyclesPlugin", False)
    recorder.SetImageWidth(1)
    recorder.SetPrimaryCameraPrimPath(camera.GetPath())

    record_start = time.monotonic()
    if not recorder.Record(stage, camera, 0.0, args.image):
        raise RuntimeError("FrameRecorder.Record failed")
    record_seconds = time.monotonic() - record_start
    print(json.dumps({"event": "record_complete", "seconds": record_seconds}), flush=True)

    teardown_start = time.monotonic()
    recorder = None
    gc.collect()
    teardown_seconds = time.monotonic() - teardown_start
    print(json.dumps({"event": "teardown_complete", "seconds": teardown_seconds}), flush=True)

    with open(args.result, "w", encoding="utf-8") as output:
        json.dump(
            {
                "record_seconds": record_seconds,
                "teardown_seconds": teardown_seconds,
            },
            output,
            indent=2,
            sort_keys=True,
        )
        output.write("\n")


if __name__ == "__main__":
    main()
