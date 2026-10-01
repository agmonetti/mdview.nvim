#include <cerrno>
#include <cstdlib>
#include <iostream>
#include <string>
#include <memory>
#include <stdexcept>

// Adapter provided by litehtml v0.10, compiled with the system Cairo/Pango.
#include "octicons.hpp"

static bool render_png(const std::string& input, const std::string& output, int width) {
    html2png::html_config cfg(input);
    std::ifstream stream(input, std::ios::binary);
    if (!stream) throw std::runtime_error("Cannot read: " + input);
    const std::string html{std::istreambuf_iterator<char>(stream), {}};
    html2png::converter converter(width, 800, 96.0, "sans-serif");
    mdview::OcticonContainer container(std::filesystem::path(input).parent_path().string(), &converter);
    auto doc = litehtml::document::createFromString(html, &container);
    if (!doc) return false;
    int best_width = doc->render(width);
    if (best_width > 0 && cfg.get_bool("bestfit", true)) {
        best_width = cfg.get_int("width", best_width);
        converter = html2png::converter(best_width, 800, 96.0, "sans-serif");
        doc->render(best_width);
        converter = html2png::converter(width, 800, 96.0, "sans-serif");
    }
    const int raster_width = cfg.get_int("width", doc->width() > 0 ? doc->width() : 1);
    const int height = cfg.get_int("height", doc->height() > 0 ? doc->height() : 1);
    mdview::Surface surface(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, raster_width, height), cairo_surface_destroy);
    if (cairo_surface_status(surface.get()) != CAIRO_STATUS_SUCCESS) return false;
    auto cr = cairo_create(surface.get());
    cairo_set_source_rgb(cr, 1, 1, 1); cairo_paint(cr);
    litehtml::position clip(0, 0, raster_width, height);
    doc->draw(reinterpret_cast<litehtml::uint_ptr>(cr), 0, 0, &clip);
    const auto status = cairo_status(cr);
    cairo_destroy(cr);
    if (status != CAIRO_STATUS_SUCCESS) return false;
    auto pixbuf = gdk_pixbuf_get_from_surface(surface.get(), 0, 0, raster_width, height);
    if (!pixbuf) return false;
    const bool saved = gdk_pixbuf_save(pixbuf, output.c_str(), "png", nullptr, nullptr);
    g_object_unref(pixbuf);
    return saved;
}

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
    try {
        if (!render_png(argv[1], argv[2], width)) {
            std::cerr << "Could not render: " << argv[1] << "\n";
            return 1;
        }
    } catch (const std::exception& e) {
        std::cerr << e.what() << "\n";
        return 1;
    }
    std::cout << "Generated PNG: " << argv[2] << "\n";
    return 0;
}
