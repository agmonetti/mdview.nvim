#pragma once
// HTML-only closed-format local image decoder; Markdown images retain the adapter loader.
#include <array>
#include <filesystem>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace html_images {
constexpr uint64_t axis_limit = 8192;
constexpr uint64_t image_pixels = 16ull * 1024 * 1024;
constexpr uint64_t layout_pixels = 32ull * 1024 * 1024;
constexpr uint64_t encoded_bytes = 64ull * 1024 * 1024;
using Surface = std::unique_ptr<cairo_surface_t, decltype(&cairo_surface_destroy)>;
struct Entry {
    Surface image{nullptr, cairo_surface_destroy};
    std::string reason;
};
struct Context {
    std::filesystem::path base = ".";
    std::map<std::string, Entry> cache;
    std::map<std::string, std::string> html_sources;
    std::string token_prefix;
    uint64_t retained = 0;
    uint64_t next_source = 0;
    bool decoding = true;
};
inline Context context;
inline void clear() { context.cache.clear(); context.html_sources.clear(); context.token_prefix.clear(); context.retained = 0; context.next_source = 0; context.decoding = true; }
inline void configure(const std::string& base, const std::string& scope = {}) {
    clear();
    context.base = base.empty() ? "." : base;
    static constexpr char digits[] = "0123456789abcdef";
    context.token_prefix = "mdview-html:";
    for (unsigned char byte : scope) {
        context.token_prefix += digits[byte >> 4];
        context.token_prefix += digits[byte & 15];
    }
    context.token_prefix += ':';
}
inline std::string register_html_source(const std::string& src) {
    const auto token = context.token_prefix + std::to_string(context.next_source++);
    context.html_sources[token] = src;
    return token;
}
inline int nibble(unsigned char c) {
    if (c >= '0' && c <= '9') return c-'0';
    if (c >= 'a' && c <= 'f') return c-'a'+10;
    if (c >= 'A' && c <= 'F') return c-'A'+10;
    return -1;
}
inline bool local_url(const std::string& src, std::string& path, std::string& reason) {
    path.clear();
    auto fail = [&] { reason = "invalid or nonlocal image URL"; return false; };
    if (src.empty()) return fail();
    // Only path URLs: reject schemes, authorities, queries and fragments before and after decoding.
    auto safe = [](const std::string& value) {
        if (value.empty() || value.compare(0, 2, "//") == 0) return false;
        for (unsigned char c : value) if (c < 32 || c == 127 || c == ':' || c == '\\' || c == '?' || c == '#') return false;
        return true;
    };
    if (!safe(src)) return fail();
    std::string decoded;
    decoded.reserve(src.size());
    for (size_t i = 0; i < src.size(); ++i) {
        if (src[i] != '%') { decoded += src[i]; continue; }
        if (i+2 >= src.size()) return fail();
        const int a = nibble(src[i+1]), b = nibble(src[i+2]);
        if (a < 0 || b < 0) return fail();
        decoded += static_cast<char>((a << 4) | b); i += 2;
    }
    if (!safe(decoded) || !g_utf8_validate(decoded.data(), decoded.size(), nullptr)) return fail();
    auto local = std::filesystem::path(decoded);
    if (!local.is_absolute()) local = context.base / local;
    path = std::filesystem::absolute(local).lexically_normal().string();
    return true;
}
inline bool dimensions(uint64_t w, uint64_t h, uint64_t available) {
    return w && h && w <= axis_limit && h <= axis_limit && w*h <= image_pixels && w*h <= available;
}
struct Bytes {
    int fd;
    size_t length;
    mutable std::array<unsigned char, 4096> buffer{};
    mutable size_t start = static_cast<size_t>(-1), count = 0;
    mutable bool failed = false;
    size_t size() const { return length; }
    unsigned char operator[](size_t p) const {
        if (p >= length) { failed = true; return 0; }
        if (start == static_cast<size_t>(-1) || p < start || p-start >= count) {
            start = p;
            const auto n = ::pread(fd, buffer.data(), std::min(buffer.size(), length-p), p);
            if (n <= 0) { failed = true; count = 0; return 0; }
            count = static_cast<size_t>(n);
        }
        return buffer[p-start];
    }
    bool matches(size_t p, const char* text, size_t n) const {
        for (size_t i = 0; i < n; ++i) if ((*this)[p+i] != static_cast<unsigned char>(text[i])) return false;
        return true;
    }
};
inline uint32_t le(const Bytes& b, size_t p, size_t n) {
    uint32_t v = 0; for (size_t i = 0; i < n; ++i) v |= uint32_t(b[p+i]) << (8*i); return v;
}
inline uint32_t be(const Bytes& b, size_t p, size_t n) {
    uint32_t v = 0; for (size_t i = 0; i < n; ++i) v = (v << 8) | b[p+i]; return v;
}
struct Header { const char* format = nullptr; uint32_t width = 0, height = 0; };
inline Header header(const Bytes& b) {
    Header h;
    const size_t size = b.size();
    if (size >= 24 && b.matches(0, "\211PNG\r\n\032\n", 8) && b.matches(12, "IHDR", 4))
        return {"png", be(b, 16, 4), be(b, 20, 4)};
    if (size >= 4 && b[0] == 255 && b[1] == 216) {
        size_t p = 2;
        while (p+4 <= size) {
            if (b[p++] != 255) return h;
            while (p < size && b[p] == 255) ++p;
            if (p >= size) return h;
            const unsigned marker = b[p++];
            if (marker == 217 || marker == 218 || marker == 0) return h;
            if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
            if (p+2 > size) return h;
            const size_t n = be(b, p, 2);
            if (n < 2 || n > size-p) return h;
            if (marker >= 192 && marker <= 207 && marker != 196 && marker != 200 && marker != 204) {
                if (n < 8) return h;
                return {"jpeg", be(b, p+5, 2), be(b, p+3, 2)};
            }
            p += n;
        }
        return h;
    }
    if (size >= 13 && (b.matches(0, "GIF87a", 6) || b.matches(0, "GIF89a", 6))) {
        h = {"gif", le(b, 6, 2), le(b, 8, 2)};
        size_t p = 13 + ((b[10] & 128) ? 3u * (2u << (b[10] & 7)) : 0);
        unsigned frames = 0;
        auto blocks = [&] {
            while (p < size) { size_t n = b[p++]; if (!n) return true; if (n > size-p) return false; p += n; }
            return false;
        };
        while (p < size) {
            const unsigned kind = b[p++];
            if (kind == 59) return frames == 1 ? h : Header{};
            if (kind == 33) { if (p >= size) return {}; ++p; if (!blocks()) return {}; continue; }
            if (kind != 44 || p+9 > size || ++frames > 1) return {};
            const uint32_t x = le(b, p, 2), y = le(b, p+2, 2), w = le(b, p+4, 2), height = le(b, p+6, 2);
            if (!w || !height || x+w > h.width || y+height > h.height) return {};
            const unsigned packed = b[p+8]; p += 9;
            if (packed & 128) p += 3u * (2u << (packed & 7));
            if (p >= size) return {};
            ++p; if (!blocks()) return {};
        }
        return {};
    }
    if (size >= 26 && b[0] == 'B' && b[1] == 'M') {
        const uint32_t dib = le(b, 14, 4);
        if (dib == 12) return {"bmp", le(b, 18, 2), le(b, 20, 2)};
        if (dib >= 40 && size >= 54) {
            const int32_t w = static_cast<int32_t>(le(b, 18, 4)), height = static_cast<int32_t>(le(b, 22, 4));
            if (w <= 0 || height == 0 || height == INT32_MIN) return {};
            return {"bmp", static_cast<uint32_t>(w), static_cast<uint32_t>(height < 0 ? -height : height)};
        }
        return {};
    }
    if (size >= 20 && b.matches(0, "RIFF", 4) && b.matches(8, "WEBP", 4)) {
        size_t p = 12;
        Header canvas;
        while (p+8 <= size) {
            const size_t n = le(b, p+4, 4), data = p+8;
            if (n > size-data) return {};
            if (b.matches(p, "ANIM", 4) || b.matches(p, "ANMF", 4)) return {};
            if (b.matches(p, "VP8X", 4)) {
                if (n < 10 || (b[data] & 2)) return {};
                canvas = {"webp", 1+le(b, data+4, 3), 1+le(b, data+7, 3)};
            } else if (b.matches(p, "VP8 ", 4)) {
                if (n < 10 || b[data+3] != 157 || b[data+4] != 1 || b[data+5] != 42) return {};
                h = {"webp", le(b, data+6, 2) & 16383u, le(b, data+8, 2) & 16383u};
            } else if (b.matches(p, "VP8L", 4)) {
                if (n < 5 || b[data] != 47) return {};
                const uint32_t bits = le(b, data+1, 4);
                h = {"webp", 1+(bits & 16383u), 1+((bits >> 14) & 16383u)};
            }
            p = data+n+(n & 1);
        }
        if (canvas.format && h.format && (canvas.width != h.width || canvas.height != h.height)) return {};
        return canvas.format ? canvas : h;
    }
    return h;
}
struct Gate { uint32_t width, height; uint64_t available; bool seen = false, rejected = false; };
inline void size_prepared(GdkPixbufLoader* loader, int width, int height, gpointer data) {
    auto& gate = *static_cast<Gate*>(data);
    gate.seen = true;
    if (width != static_cast<int>(gate.width) || height != static_cast<int>(gate.height)
        || !dimensions(width > 0 ? width : 0, height > 0 ? height : 0, gate.available)) {
        gate.rejected = true;
        // Request zero output on a header mismatch; never substitute a smaller accepted image.
        // Independent intrinsic-header gates reject oversize input before creating the loader.
        gdk_pixbuf_loader_set_size(loader, 0, 0);
    }
}
inline void decode(const std::string& path, Entry& entry) {
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { entry.reason = "cannot open local image"; return; }
    struct File { int fd; ~File() { ::close(fd); } } file{fd};
    struct stat status{};
    if (::fstat(fd, &status) || !S_ISREG(status.st_mode) || status.st_size < 0
        || static_cast<uint64_t>(status.st_size) > encoded_bytes) {
        entry.reason = "image must be a regular file within 64MiB encoded budget"; return;
    }
    Bytes bytes{fd, static_cast<size_t>(status.st_size)};
    const auto info = header(bytes);
    if (bytes.failed) { entry.reason = "cannot read local image header"; return; }
    if (!info.format) { entry.reason = "unsupported or corrupt image (static PNG/JPEG/GIF/BMP/WebP only)"; return; }
    const uint64_t available = layout_pixels-context.retained;
    if (!dimensions(info.width, info.height, available)) { entry.reason = "intrinsic image dimensions exceed pixel safety budget"; return; }
    GError* error = nullptr;
    auto loader = gdk_pixbuf_loader_new_with_type(info.format, &error);
    if (error) g_error_free(error);
    if (!loader) { entry.reason = "installed Gdk image decoder unavailable"; return; }
    Gate gate{info.width, info.height, available};
    struct Loader {
        GdkPixbufLoader* pointer;
        bool closed = false;
        ~Loader() { if (!closed) gdk_pixbuf_loader_close(pointer, nullptr); g_object_unref(pointer); }
    } owner{loader};
    g_signal_connect(loader, "size-prepared", G_CALLBACK(size_prepared), &gate);
    bool written = true;
    size_t used = 0;
    std::array<unsigned char, 4096> chunk{};
    while (used < bytes.size() && written && !gate.rejected) {
        const auto n = ::read(fd, chunk.data(), std::min(chunk.size(), bytes.size()-used));
        if (n <= 0) { written = false; break; }
        used += static_cast<size_t>(n);
        written = gdk_pixbuf_loader_write(loader, chunk.data(), n, nullptr);
    }
    unsigned char extra;
    if (used != bytes.size() || ::read(fd, &extra, 1) != 0) written = false;
    const bool closed = gdk_pixbuf_loader_close(loader, nullptr);
    owner.closed = true;
    auto pixbuf = written && closed && gate.seen && !gate.rejected ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
    if (!pixbuf || gdk_pixbuf_get_width(pixbuf) != static_cast<int>(info.width)
        || gdk_pixbuf_get_height(pixbuf) != static_cast<int>(info.height)) {
        entry.reason = gate.rejected ? "intrinsic image dimensions exceed pixel safety budget" : "corrupt local image";
        return;
    }
    const bool alpha = gdk_pixbuf_get_has_alpha(pixbuf);
    Surface surface(cairo_image_surface_create(alpha ? CAIRO_FORMAT_ARGB32 : CAIRO_FORMAT_RGB24, info.width, info.height), cairo_surface_destroy);
    if (cairo_surface_status(surface.get()) != CAIRO_STATUS_SUCCESS) {
        entry.reason = "cannot allocate local image surface"; return;
    }
    // Match Gdk's Cairo premultiplication, without Gdk's display-dependent surface factory.
    const auto* source = gdk_pixbuf_get_pixels(pixbuf);
    const int source_stride = gdk_pixbuf_get_rowstride(pixbuf), channels = gdk_pixbuf_get_n_channels(pixbuf);
    auto* target = cairo_image_surface_get_data(surface.get());
    const int target_stride = cairo_image_surface_get_stride(surface.get());
    auto premultiply = [](unsigned v, unsigned a) { const unsigned t = v*a+128; return (t+(t >> 8)) >> 8; };
    for (uint32_t y = 0; y < info.height; ++y) {
        const auto* row = source+static_cast<size_t>(y)*source_stride;
        auto* output = reinterpret_cast<uint32_t*>(target+static_cast<size_t>(y)*target_stride);
        for (uint32_t x = 0; x < info.width; ++x) {
            const auto* p = row+static_cast<size_t>(x)*channels;
            const unsigned a = alpha ? p[3] : 255;
            output[x] = (a << 24) | (premultiply(p[0], a) << 16) | (premultiply(p[1], a) << 8) | premultiply(p[2], a);
        }
    }
    cairo_surface_mark_dirty(surface.get());
    context.retained += uint64_t(info.width)*info.height;
    entry.image = std::move(surface);
}
inline cairo_surface_t* surface(const std::string& src, std::string* reason = nullptr) {
    std::string path, failure;
    if (!local_url(src, path, failure)) { if (reason) *reason = failure; return nullptr; }
    auto found = context.cache.find(path);
    if (found == context.cache.end()) {
        if (!context.decoding) { if (reason) *reason = "image not prepared during layout"; return nullptr; }
        auto inserted = context.cache.emplace(path, Entry{});
        found = inserted.first;
        decode(path, found->second);
    }
    if (reason) *reason = found->second.reason;
    return found->second.image.get();
}
inline bool preflight(const std::string& src, std::string& reason) { return surface(src, &reason) != nullptr; }
} // namespace html_images
