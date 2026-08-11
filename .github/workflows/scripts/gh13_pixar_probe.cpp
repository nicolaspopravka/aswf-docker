#include <pxr/imaging/hio/image.h>
#include <cstdio>
int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: hio_probe <image>\n"); return 2; }
    pxr::HioImageSharedPtr img = pxr::HioImage::OpenForReading(argv[1]);
    if (!img) { printf("HioImage::OpenForReading FAILED for %s\n", argv[1]); return 1; }
    printf("HioImage open OK w=%d h=%d file=%s\n",
           img->GetWidth(), img->GetHeight(), img->GetFilename().c_str());
    return 0;
}
