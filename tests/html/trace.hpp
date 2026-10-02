#pragma once
// Test-only oracle: TEXT rows originate in Cairo's draw callback, never in source attribution.
static void html_trace_text(const char* text, const litehtml::position& pos) {
    const char* path = std::getenv("MDVIEW_HTML_TRACE");
    if (!path || !*path) return;
    std::ofstream out(path, std::ios::app);
    if (!out) throw std::runtime_error("Cannot write HTML draw trace");
    out << "TEXT\t" << hex(text) << '\t' << pos.x << '\t' << pos.y << '\t' << pos.width << '\t' << pos.height << '\n';
}
static void html_trace_fragment(const Fragment& fragment, const std::string& text) {
    const char* path = std::getenv("MDVIEW_HTML_TRACE");
    if (!path || !*path) return;
    std::ofstream out(path, std::ios::app);
    if (!out) throw std::runtime_error("Cannot write HTML fragment trace");
    out << "FRAG\t" << fragment.line << '\t' << fragment.column << '\t' << fragment.end << '\t'
        << fragment.y << '\t' << fragment.bottom << '\t' << hex(text) << '\n';
}
static int html_render_file(const char* input, const char* width_arg, const char* height_arg, const char* output) {
    try {
        const int width = std::stoi(width_arg), height = std::stoi(height_arg);
        if (width < 64 || width > 4096 || height < 1 || height > 16384) throw std::runtime_error("Invalid HTML render dimensions");
        html2png::converter converter(width, height, 96.0, "sans-serif");
        MermaidRenderer renderer;
        Container container(".", &converter, &renderer);
        auto document = litehtml::document::createFromString(read_file(input), &container);
        if (!document) throw std::runtime_error("Cannot create HTML test document");
        document->render(width);
        html_images::context.decoding = false;
        auto surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
        if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(surface); throw std::runtime_error("Cannot allocate HTML test surface"); }
        auto cr = cairo_create(surface);
        cairo_set_source_rgb(cr, 13/255.0, 17/255.0, 23/255.0); cairo_paint(cr);
        litehtml::position clip(0, 0, width, height);
        document->draw(reinterpret_cast<litehtml::uint_ptr>(cr), 0, 0, &clip);
        const auto status = cairo_status(cr);
        cairo_destroy(cr);
        cairo_surface_flush(surface);
        const auto* data = cairo_image_surface_get_data(surface);
        const int stride = cairo_image_surface_get_stride(surface);
        std::ofstream file(output, std::ios::binary);
        std::vector<unsigned char> rgba(static_cast<size_t>(width) * 4);
        for (int y = 0; y < height; ++y) {
            const auto* row = reinterpret_cast<const uint32_t*>(data + y*stride);
            for (int x = 0; x < width; ++x) {
                const uint32_t p = row[x]; const unsigned a = p >> 24;
                auto* pixel = &rgba[static_cast<size_t>(x) * 4];
                for (int c = 0; c < 3; ++c) {
                    const unsigned v = (p >> (16-c*8)) & 255;
                    pixel[c] = static_cast<unsigned char>(a == 255 ? v : (a ? std::min(255u, (v*255+a/2)/a) : 0));
                }
                pixel[3] = static_cast<unsigned char>(a);
            }
            file.write(reinterpret_cast<const char*>(rgba.data()), rgba.size());
        }
        cairo_surface_destroy(surface);
        if (!file || status != CAIRO_STATUS_SUCCESS) throw std::runtime_error("Cannot write HTML test RGBA");
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
