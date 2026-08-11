#include <OpenImageIO/imageio.h>
#include <cstdio>
int main(int argc, char** argv) {
    if (argc < 2) return 2;
    auto in = OIIO::ImageInput::open(argv[1]);
    if (!in) {
        printf("ImageInput::open FAILED: %s\n", OIIO::geterror().c_str());
        return 1;
    }
    printf("ImageInput open OK: %dx%d tiled=%dx%d\n",
           in->spec().width, in->spec().height,
           in->spec().tile_width, in->spec().tile_height);
    int miplevels = 0;
    while (in->seek_subimage(0, miplevels))
        ++miplevels;
    printf("mip levels: %d\n", miplevels);
    return 0;
}
