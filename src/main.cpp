#include <cerrno>
#include <cstdlib>
#include <iostream>
#include <string>

// Adapter provided by litehtml v0.10, compiled with the system Cairo/Pango.
#include "render2png.h"

int main(int argc, char** argv) {
    if (argc < 3 || argc > 4) {
        std::cerr << "Usage: mdview-render input.html output.png [width=900]\n";
        return 2;
    }
    int width = 900;
    if (argc == 4) {
        char* end = nullptr;
        errno = 0;
        const long parsed = std::strtol(argv[3], &end, 10);
        if (errno || end == argv[3] || *end || parsed < 320 || parsed > 2400) {
            std::cerr << "Valid width: 320..2400 px\n";
            return 2;
        }
        width = static_cast<int>(parsed);
    }

    // The upstream renderer sizes the PNG to the full document height, rather
    // than cropping it to the nominal viewport height provided below.
    html2png::converter converter(width, 800, 96.0, "sans-serif");
    if (!converter.to_png(argv[1], argv[2])) {
        std::cerr << "Could not render: " << argv[1] << "\n";
        return 1;
    }
    std::cout << "Generated PNG: " << argv[2] << "\n";
    return 0;
}
