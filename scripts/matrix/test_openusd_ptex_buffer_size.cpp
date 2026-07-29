// Copyright (c) Contributors to the aswf-docker Project.
// SPDX-License-Identifier: Apache-2.0

#include "pxr/imaging/hdSt/ptexMipmapTextureLoaderSizing.h"

#include <cassert>
#include <cstddef>
#include <iostream>
#include <limits>

static void
Check(
    int bpp,
    int width,
    int height,
    size_t pages,
    HdStPtexBufferSizeResult expectedResult,
    size_t expectedStride,
    size_t expectedTotal)
{
    size_t stride = 0;
    size_t total = 0;
    const HdStPtexBufferSizeResult result =
        HdStComputePtexBufferSize(
            bpp, width, height, pages, &stride, &total);
    assert(result == expectedResult);
    assert(stride == expectedStride);
    assert(total == expectedTotal);
}

int
main()
{
    Check(
        4, 1024, 1024, 2,
        HdStPtexBufferSizeResult::Success,
        4194304, 8388608);

    // Captured /island/isBeach values.
    Check(
        3, 772, 514, 2741,
        HdStPtexBufferSizeResult::ExceedsSupportedSize,
        1190424, 3262952184ULL);

    // Captured /island/isDunesB values. The old signed-int expression
    // wrapped this total to 302846656, the exact GDB _memoryUsage value.
    Check(
        3, 12292, 8194, 200,
        HdStPtexBufferSizeResult::ExceedsSupportedSize,
        302161944, 60432388800ULL);

    size_t result = 0;
    assert(!HdStCheckedMultiplySize(
        std::numeric_limits<size_t>::max(), 2, &result));

    std::cout << "OpenUSD Ptex buffer-size regression cases passed\n";
}
