#!/usr/bin/env python3
"""Generate an isolated preview source, asserting every production hook exactly once."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
if out == root or out == root / "src" or root / "src" in out.parents:
    raise SystemExit("The experimental generator must not write production paths")
out.mkdir(parents=True, exist_ok=True)
production = {path: path.read_bytes() for path in (root / "src").rglob("*") if path.is_file()}
production[root / "CMakeLists.txt"] = (root / "CMakeLists.txt").read_bytes()
source = production[root / "src/preview.cpp"].decode()

def replace(old, new):
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"HTML subset hook changed: expected one match, got {count}: {old[:100]!r}")
    source = source.replace(old, new)

replace('#include <cstdlib>\n', '#include <cstdlib>\n')
replace('#include "html_images.hpp"\n', '#include "images.hpp"\n')
replace('    #include "html_subset.hpp"\n', '    #include "subset.hpp"\n')
replace('static int html_root_label = -1;\n',
        'static int html_root_label = -1;\n'
        'static void html_trace_text(const char*, const litehtml::position&);\n'
        'static void html_trace_fragment(const Fragment&, const std::string&);\n')
replace('            if (html_enabled) sanitize_html(root, marked);\n            if (marked) instrument(root);',
        '            if (html_enabled) sanitize_html(root, marked);\n            if (marked) instrument(root);')
replace('''            std::string html = html_annotate(rendered.get());
            cmark_node_free(root); cmark_parser_free(parser);''', '''            std::string html = html_annotate(rendered.get());
            cmark_node_free(root); cmark_parser_free(parser);''')
replace('''        : mdview::OcticonContainer(base, converter), mermaid(renderer) {}''', '''        : mdview::OcticonContainer(base, converter), mermaid(renderer) {}
    void draw_text(litehtml::uint_ptr hdc, const char* text, litehtml::uint_ptr font,
                   litehtml::web_color color, const litehtml::position& position) override {
        html_trace_text(text, position);
        mdview::OcticonContainer::draw_text(hdc, text, font, color, position);
    }''')
replace('''    cairo_surface_t* get_image(const std::string& url) override {
        const auto html = html_images::context.html_sources.find(url);
        if (html != html_images::context.html_sources.end()) {
            auto image = html_images::surface(html->second);
            return image ? cairo_surface_reference(image) : nullptr;
        }
        if (url.find("://") != std::string::npos || url.find("data:") != std::string::npos) return nullptr;
        for (size_t i=0; i<url.size(); ++i) if (url[i]=='%') {
            if (i+2 >= url.size() || !std::isxdigit(static_cast<unsigned char>(url[i+1])) || !std::isxdigit(static_cast<unsigned char>(url[i+2]))) return nullptr;
            i += 2;
        }
        auto image = html2png::container::get_image(url);
        if (!image && mermaid->owns_image(url)) throw std::runtime_error("Cannot decode Mermaid PNG");
        return image;
    }''', '''    void make_url(const char* url, const char*, std::string& out) override { out = url ? url : ""; }
    cairo_surface_t* get_image(const std::string& url) override {
        auto image = html_images::surface(url);
        if (!image && mermaid->owns_image(url)) throw std::runtime_error("Cannot decode Mermaid PNG");
        return image ? cairo_surface_reference(image) : nullptr;
    }
    void draw_image(litehtml::uint_ptr hdc, const litehtml::background_layer& layer,
                    const std::string& url, const std::string& base) override {
        html_images::context.decoding = false;
        html_images::trace_image(url, layer.origin_box);
        mdview::OcticonContainer::draw_image(hdc, layer, url, base);
    }''')
replace('''                fragments.push_back({first.line, first.column, last.column, placement.y, 0, static_cast<double>(placement.y + placement.height)});''', '''                fragments.push_back({first.line, first.column, last.column, placement.y, 0, static_cast<double>(placement.y + placement.height)});
                html_trace_fragment(fragments.back(), text);''')
replace('''                fragments.push_back({line, first_column, last_column, placement.y, 0,
                    static_cast<double>(placement.y + placement.height)});''',
        '''                fragments.push_back({line, first_column, last_column, placement.y, 0,
                    static_cast<double>(placement.y + placement.height)});
                html_trace_fragment(fragments.back(), "");''')
replace('''            std::cout << "ERROR " << hex(e.what()) << '\\n';
        }
    }
}
''', '''            std::cout << "ERROR " << hex(e.what()) << '\\n';
        }
    }
    doc.reset(); container.reset(); converter.reset();
    html_images::clear();
}
''')
replace('''int main(int argc, char** argv) {
    std::cout << std::unitbuf;''', '''#include "trace.hpp"
int main(int argc, char** argv) {
    if (argc == 6 && std::string(argv[1]) == "--render-html") {
        html_images::configure(std::filesystem::path(argv[2]).parent_path().string());
        return html_render_file(argv[2], argv[3], argv[4], argv[5]);
    }
    std::cout << std::unitbuf;''')
(out / "preview.cpp").write_text(source)
(out / ".clangd").write_text("CompileFlags:\n  CompilationDatabase: .\n")
# A separate CMake project consumes only existing native dependencies and the pinned local adapter.
cmake = r'''cmake_minimum_required(VERSION 3.20)
project(mdview_html_subset LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(ROOT "@ROOT@")
set(CAIRO_DIR "${ROOT}/third_party/litehtml/containers/cairo")
if(NOT EXISTS "${CAIRO_DIR}/render2png.cpp")
    message(FATAL_ERROR "Existing third_party/litehtml is required; this experimental build never downloads dependencies")
endif()
find_package(PkgConfig REQUIRED)
pkg_check_modules(RENDER_LIBS REQUIRED IMPORTED_TARGET gdk-3.0 cairo pango pangocairo fontconfig)
pkg_check_modules(CMARK REQUIRED IMPORTED_TARGET libcmark-gfm)
find_library(LITEHTML_LIBRARY NAMES litehtml REQUIRED)
find_path(LITEHTML_INCLUDE_DIR NAMES litehtml.h PATH_SUFFIXES litehtml REQUIRED)
foreach(icon info light-bulb report alert stop)
    file(READ "${ROOT}/assets/octicons/${icon}-16.svg" "OCTICON_${icon}")
endforeach()
configure_file("${ROOT}/src/octicons_data.hpp.in" "${CMAKE_BINARY_DIR}/generated/octicons_data.hpp" @ONLY)
add_executable(mdview-preview preview.cpp
    "${CAIRO_DIR}/cairo_borders.cpp"
    "${CAIRO_DIR}/container_cairo.cpp"
    "${CAIRO_DIR}/container_cairo_pango.cpp"
    "${CAIRO_DIR}/conic_gradient.cpp")
target_include_directories(mdview-preview PRIVATE "${ROOT}/src" "${ROOT}/tests/html" "${CAIRO_DIR}"
    "${ROOT}/third_party/litehtml/include" "${LITEHTML_INCLUDE_DIR}" "${CMAKE_BINARY_DIR}/generated")
target_link_libraries(mdview-preview PRIVATE PkgConfig::RENDER_LIBS PkgConfig::CMARK "${LITEHTML_LIBRARY}")
target_compile_options(mdview-preview PRIVATE -Wall -Wextra)
'''.replace('@ROOT@', root.as_posix().replace('"', '\\"'))
(out / "CMakeLists.txt").write_text(cmake)
if any(path.read_bytes() != original for path, original in production.items()):
    raise SystemExit("Production sources changed during experimental generation")
