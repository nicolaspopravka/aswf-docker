#!/usr/bin/env python3

import argparse
import struct
import zlib


def _paeth(left, above, upper_left):
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def _read_png(path):
    with open(path, "rb") as stream:
        data = stream.read()

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

    if bit_depth != 8 or color_type not in (0, 2, 6) or interlace != 0:
        raise ValueError(
            f"unsupported PNG layout: depth={bit_depth}, "
            f"color_type={color_type}, interlace={interlace}"
        )

    channels = {0: 1, 2: 3, 6: 4}[color_type]
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise ValueError(f"unexpected decompressed size: {len(raw)} != {expected}")

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
                predictor = _paeth(left, above, upper_left)
            else:
                raise ValueError(f"unsupported PNG filter {filter_type}")
            decoded[index] = (value + predictor) & 0xFF
        rows.append(decoded)
        previous = decoded

    pixels = []
    for row in rows:
        for offset in range(0, len(row), channels):
            if channels == 1:
                pixel = (row[offset],) * 3
            else:
                pixel = tuple(row[offset : offset + 3])
            pixels.append(pixel)
    return width, height, pixels


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("--expected-width", type=int, default=128)
    args = parser.parse_args()

    width, height, pixels = _read_png(args.image)
    unique_pixels = len(set(pixels))
    luminance = [
        (2126 * red + 7152 * green + 722 * blue) // 10000
        for red, green, blue in pixels
    ]
    luminance_range = max(luminance) - min(luminance)

    print(f"size={width}x{height}")
    print(f"unique_rgb_pixels={unique_pixels}")
    print(f"luminance_range={luminance_range}")

    if width != args.expected_width or height < 1:
        raise SystemExit("unexpected image dimensions")
    if unique_pixels < 16:
        raise SystemExit("render is effectively uniform")
    if luminance_range < 10:
        raise SystemExit("render has insufficient pixel variation")


if __name__ == "__main__":
    main()
