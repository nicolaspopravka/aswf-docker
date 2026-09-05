#!/usr/bin/env python3

import argparse
import struct
import zlib


def paeth(left, above, upper_left):
    estimate = left + above - upper_left
    distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
    return (left, above, upper_left)[distances.index(min(distances))]


def read_png(path):
    data = open(path, "rb").read()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("output is not a PNG")
    offset = 8
    compressed = bytearray()
    width = height = bit_depth = color_type = interlace = None
    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", chunk_data
            )
        elif chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        elif chunk_type == b"IEND":
            break
    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise ValueError("unsupported PNG layout")
    channels = {2: 3, 6: 4}[color_type]
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    rows = []
    previous = bytearray(stride)
    position = 0
    for _ in range(height):
        filter_type = raw[position]
        position += 1
        encoded = raw[position : position + stride]
        position += stride
        decoded = bytearray(stride)
        for index, value in enumerate(encoded):
            left = decoded[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                predictor = paeth(left, above, upper_left)
            else:
                raise ValueError(f"unsupported PNG filter {filter_type}")
            decoded[index] = (value + predictor) & 0xFF
        rows.append(decoded)
        previous = decoded
    return width, height, [
        tuple(row[offset : offset + 3])
        for row in rows
        for offset in range(0, len(row), channels)
    ]


parser = argparse.ArgumentParser()
parser.add_argument("image")
parser.add_argument("--mode", choices=("udim", "cyan"), required=True)
args = parser.parse_args()

width, height, pixels = read_png(args.image)
print(f"size={width}x{height}")
if args.mode == "udim":
    red = sum(r > 1.5 * g and r > 1.5 * b and r > 32 for r, g, b in pixels)
    green = sum(g > 1.5 * r and g > 1.5 * b and g > 32 for r, g, b in pixels)
    print(f"red_dominant_pixels={red}")
    print(f"green_dominant_pixels={green}")
    if width != 256 or height < 1 or red < 100 or green < 100:
        raise SystemExit("both UDIM tile colors were not rendered")
else:
    cyan = sum(g > 1.5 * r and b > 1.5 * r and g > 32 and b > 32 for r, g, b in pixels)
    print(f"cyan_dominant_pixels={cyan}")
    if width != 128 or height < 1 or cyan < 100:
        raise SystemExit("ordinary cyan texture was not rendered")
