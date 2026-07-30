#!/usr/bin/env python3
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import argparse
import hashlib
import json
import math
from pathlib import Path

import OpenImageIO as oiio
import numpy


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--require-variation", action="store_true")
    args = parser.parse_args()

    image = oiio.ImageInput.open(str(args.image))
    if image is None:
        raise SystemExit(f"cannot open image: {args.image}")
    try:
        spec = image.spec()
        pixels = image.read_image(oiio.FLOAT)
    finally:
        image.close()

    if pixels is None:
        raise SystemExit(f"cannot read pixels: {args.image}")

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

    varying = any(
        math.isfinite(low) and math.isfinite(high) and high - low > 1.0e-6
        for low, high in zip(minima, maxima)
    )
    result = {
        "path": str(args.image),
        "sha256": hashlib.sha256(args.image.read_bytes()).hexdigest(),
        "width": spec.width,
        "height": spec.height,
        "channels": spec.channelnames,
        "min": minima,
        "max": maxima,
        "finite_samples": finite_samples,
        "pixel_varying": varying,
    }
    print(json.dumps(result, indent=2, sort_keys=True))

    if finite_samples == 0:
        raise SystemExit("image has no finite samples")
    if args.require_variation and not varying:
        raise SystemExit("image has no pixel variation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
