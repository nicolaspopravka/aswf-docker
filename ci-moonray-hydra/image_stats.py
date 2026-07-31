#!/usr/bin/env python3
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

import numpy

try:
    import OpenImageIO as oiio
except ModuleNotFoundError:
    oiio = None


def read_with_oiiotool(image_path: Path):
    completed = subprocess.run(
        ["oiiotool", "--info", "-v", "--stats", str(image_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    output = completed.stdout

    geometry = re.search(r":\s+(\d+)\s+x\s+(\d+),\s+(\d+) channel", output)
    channels = re.search(r"^\s*channel list:\s*(.+)$", output, re.MULTILINE)
    if geometry is None or channels is None:
        raise SystemExit(f"cannot parse image metadata: {image_path}")

    def stats(name, value_type):
        match = re.search(
            rf"^\s*Stats {name}:\s*(.+?)(?:\s+\([^)]*\))?\s*$",
            output,
            re.MULTILINE,
        )
        if match is None:
            raise SystemExit(f"cannot parse {name} statistics: {image_path}")
        return [value_type(value) for value in match.group(1).split()]

    return {
        "width": int(geometry.group(1)),
        "height": int(geometry.group(2)),
        "channels": [channel.strip() for channel in channels.group(1).split(",")],
        "min": stats("Min", float),
        "max": stats("Max", float),
        "finite_samples": sum(stats("FiniteCount", int)),
    }


def read_with_python_binding(image_path: Path):
    image = oiio.ImageInput.open(str(image_path))
    if image is None:
        raise SystemExit(f"cannot open image: {image_path}")
    try:
        spec = image.spec()
        pixels = image.read_image(oiio.FLOAT)
    finally:
        image.close()

    if pixels is None:
        raise SystemExit(f"cannot read pixels: {image_path}")

    channel_count = spec.nchannels
    minima = [math.inf] * channel_count
    maxima = [-math.inf] * channel_count
    finite_samples = 0
    for index, value in enumerate(numpy.asarray(pixels).reshape(-1)):
        value = float(value)
        if not math.isfinite(value):
            continue
        channel = index % channel_count
        minima[channel] = min(minima[channel], value)
        maxima[channel] = max(maxima[channel], value)
        finite_samples += 1

    return {
        "width": spec.width,
        "height": spec.height,
        "channels": spec.channelnames,
        "min": minima,
        "max": maxima,
        "finite_samples": finite_samples,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--require-variation", action="store_true")
    args = parser.parse_args()

    image_stats = (
        read_with_python_binding(args.image)
        if oiio is not None
        else read_with_oiiotool(args.image)
    )

    varying = any(
        math.isfinite(low) and math.isfinite(high) and high - low > 1.0e-6
        for low, high in zip(image_stats["min"], image_stats["max"])
    )
    result = {
        "path": str(args.image),
        "sha256": hashlib.sha256(args.image.read_bytes()).hexdigest(),
        **image_stats,
        "pixel_varying": varying,
    }
    print(json.dumps(result, indent=2, sort_keys=True))

    if image_stats["finite_samples"] == 0:
        raise SystemExit("image has no finite samples")
    if args.require_variation and not varying:
        raise SystemExit("image has no pixel variation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
