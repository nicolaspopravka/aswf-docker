#!/usr/bin/env python3

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_png_variation import _read_png


width, height, pixels = _read_png(sys.argv[1])
red = sum(r > 1.5 * g and r > 1.5 * b and r > 32 for r, g, b, _ in pixels)
green = sum(g > 1.5 * r and g > 1.5 * b and g > 32 for r, g, b, _ in pixels)

print(f"size={width}x{height}")
print(f"red_dominant_pixels={red}")
print(f"green_dominant_pixels={green}")

if width != 256 or height < 1:
    raise SystemExit("unexpected image dimensions")
if red < 100 or green < 100:
    raise SystemExit("both UDIM tile colors were not rendered")
