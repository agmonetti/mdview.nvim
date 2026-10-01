#pragma once
#include "render2png.cpp"
#include <memory>
#include "octicons_data.hpp"
#include <litehtml/html_tag.h>
#include <litehtml/render_item.h>
#include <cstring>
#include <stdexcept>

namespace mdview {
using Surface = std::unique_ptr<cairo_surface_t, decltype(&cairo_surface_destroy)>;

// Decode alpha on first use only; the five tiny masks live until worker exit.
// DRAW only paints the cached mask with the element's computed CSS color.
class OcticonElement : public litehtml::html_tag {
    cairo_surface_t* mask;
public:
    OcticonElement(const litehtml::document::ptr& doc, cairo_surface_t* image)
        : html_tag(doc), mask(image) {}
    void draw(litehtml::uint_ptr hdc, litehtml::pixel_t x, litehtml::pixel_t y,
              const litehtml::position* clip, const std::shared_ptr<litehtml::render_item>& ri) override {
        html_tag::draw(hdc, x, y, clip, ri);
        auto pos = ri->pos(); pos.x += x; pos.y += y; pos.round();
        if (!pos.does_intersect(clip) || pos.width <= 0 || pos.height <= 0) return;
        auto* cr = reinterpret_cast<cairo_t*>(hdc);
        const auto color = css().get_color();
        cairo_save(cr);
        if (clip) {
            cairo_rectangle(cr, clip->x, clip->y, clip->width, clip->height);
            cairo_clip(cr);
        }
        cairo_translate(cr, pos.x, pos.y);
        cairo_scale(cr, pos.width / 16.0, pos.height / 16.0);
        cairo_set_source_rgba(cr, color.red / 255.0, color.green / 255.0, color.blue / 255.0, color.alpha / 255.0);
        cairo_mask_surface(cr, mask, 0, 0);
        cairo_restore(cr);
    }
};

class OcticonContainer : public html2png::container {
    cairo_surface_t* mask(size_t index) {
        static std::array<Surface, 5> masks{{Surface(nullptr, cairo_surface_destroy), Surface(nullptr, cairo_surface_destroy),
            Surface(nullptr, cairo_surface_destroy), Surface(nullptr, cairo_surface_destroy), Surface(nullptr, cairo_surface_destroy)}};
        if (masks[index]) return masks[index].get();
        auto loader = gdk_pixbuf_loader_new_with_type("svg", nullptr);
        if (!loader) throw std::runtime_error("GitHub alert icons require the GdkPixbuf SVG loader");
        const auto svg = octicon_svg[index];
        const bool written = gdk_pixbuf_loader_write(loader, reinterpret_cast<const guchar*>(svg.data()), svg.size(), nullptr);
        const bool closed = gdk_pixbuf_loader_close(loader, nullptr);
        auto pixbuf = written && closed ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
        if (!pixbuf || !gdk_pixbuf_get_has_alpha(pixbuf) || gdk_pixbuf_get_width(pixbuf) != 16 || gdk_pixbuf_get_height(pixbuf) != 16) {
            g_object_unref(loader);
            throw std::runtime_error("Cannot decode bundled GitHub alert icon");
        }
        auto surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 16, 16);
        if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
            cairo_surface_destroy(surface);
            g_object_unref(loader);
            throw std::runtime_error("Cannot allocate GitHub alert icon");
        }
        const auto* pixels = gdk_pixbuf_get_pixels(pixbuf);
        auto* alpha = cairo_image_surface_get_data(surface);
        const int source_stride = gdk_pixbuf_get_rowstride(pixbuf);
        const int stride = cairo_image_surface_get_stride(surface);
        for (int y = 0; y < 16; ++y)
            for (int x = 0; x < 16; ++x) alpha[y * stride + x] = pixels[y * source_stride + x * 4 + 3];
        cairo_surface_mark_dirty(surface);
        g_object_unref(loader);
        masks[index].reset(surface);
        return surface;
    }
public:
    using html2png::container::container;
    litehtml::element::ptr create_element(const char* name, const litehtml::string_map& attributes,
                                         const litehtml::document::ptr& doc) override {
        if (std::strcmp(name, "mdview-alert-icon") != 0) return html2png::container::create_element(name, attributes, doc);
        const auto kind = attributes.find("kind");
        if (kind == attributes.end()) throw std::runtime_error("Missing GitHub alert icon kind");
        constexpr const char* kinds[] = {"note", "tip", "important", "warning", "caution"};
        for (size_t i = 0; i < 5; ++i)
            if (kind->second == kinds[i]) return std::make_shared<OcticonElement>(doc, mask(i));
        throw std::runtime_error("Unknown GitHub alert icon kind");
    }
};
}
