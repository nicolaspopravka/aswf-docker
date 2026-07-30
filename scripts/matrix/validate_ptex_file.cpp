// Copyright (c) Contributors to the aswf-docker Project.
// SPDX-License-Identifier: Apache-2.0

#include <Ptexture.h>

#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {

template <class T>
struct Release
{
    void operator()(T *value) const
    {
        if (value) {
            value->release();
        }
    }
};

bool
CheckedMultiply(size_t lhs, size_t rhs, size_t *result)
{
    if (rhs != 0 && lhs > std::numeric_limits<size_t>::max() / rhs) {
        return false;
    }
    *result = lhs * rhs;
    return true;
}

bool
Validate(const std::string &path)
{
    Ptex::String error;
    std::unique_ptr<PtexTexture, Release<PtexTexture>> texture(
        PtexTexture::open(path.c_str(), error, true));
    if (!texture) {
        std::cerr << path << ": open failed: " << error.c_str() << '\n';
        return false;
    }

    const int channels = texture->numChannels();
    const int bytesPerChannel = Ptex::DataSize(texture->dataType());
    const int faces = texture->numFaces();
    if (channels <= 0 || bytesPerChannel <= 0 || faces <= 0) {
        std::cerr << path << ": invalid header dimensions\n";
        return false;
    }

    size_t decodedBytes = 0;
    for (int face = 0; face < faces; ++face) {
        const Ptex::FaceInfo &info = texture->getFaceInfo(face);
        int ulog2 = info.res.ulog2;
        int vlog2 = info.res.vlog2;
        while (ulog2 >= 0 && vlog2 >= 0) {
            const Ptex::Res resolution(ulog2, vlog2);
            size_t rowBytes = 0;
            size_t faceBytes = 0;
            if (!CheckedMultiply(
                    static_cast<size_t>(resolution.u()),
                    static_cast<size_t>(channels * bytesPerChannel),
                    &rowBytes) ||
                !CheckedMultiply(
                    rowBytes, static_cast<size_t>(resolution.v()),
                    &faceBytes) ||
                rowBytes > static_cast<size_t>(
                    std::numeric_limits<int>::max()) ||
                decodedBytes >
                    std::numeric_limits<size_t>::max() - faceBytes) {
                std::cerr << path << ": decoded size overflow at face "
                          << face << '\n';
                return false;
            }
            std::vector<unsigned char> buffer(faceBytes);
            texture->getData(
                face, buffer.data(), static_cast<int>(rowBytes), resolution);
            decodedBytes += faceBytes;
            --ulog2;
            --vlog2;
        }
    }

    std::cout
        << "path=" << path
        << " faces=" << faces
        << " channels=" << channels
        << " dataType=" << static_cast<int>(texture->dataType())
        << " meshType=" << static_cast<int>(texture->meshType())
        << " decodedBytes=" << decodedBytes
        << " status=ok\n";
    return true;
}

} // namespace

int
main(int argc, char **argv)
{
    if (argc == 2 && std::string(argv[1]) == "--self-test") {
        std::cout << "Ptex validator runtime self-test passed\n";
        return 0;
    }
    if (argc < 2) {
        std::cerr << "usage: validate_ptex_file PTEX [PTEX ...]\n";
        return 2;
    }
    bool ok = true;
    for (int i = 1; i < argc; ++i) {
        ok = Validate(argv[i]) && ok;
    }
    return ok ? 0 : 1;
}
