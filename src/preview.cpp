// Persistent Markdown layout and bounded rasterization. Runtime: C++ + cmark-gfm.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <vector>
#include <cmark-gfm.h>
#include <cmark-gfm-core-extensions.h>
#include "render2png.cpp"
#include <litehtml/render_item.h>

using Clock = std::chrono::steady_clock;
struct Position { int line, column; };
struct Label { std::string text; std::vector<Position> positions; };
struct Fragment { int line, column, end; double y; };
static std::string read_file(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("Cannot read: " + path);
    return {std::istreambuf_iterator<char>(stream), {}};
}
static std::string hex(const std::string& s) {
    const char* digits = "0123456789abcdef";
    std::string out;
    for (unsigned char c : s) { out += digits[c >> 4]; out += digits[c & 15]; }
    return out.empty() ? "-" : out;
}
static std::string unhex(const std::string& s) {
    if (s == "-") return {};
    if (s.size() % 2) throw std::runtime_error("Invalid path encoding");
    std::string out;
    for (size_t i = 0; i < s.size(); i += 2) {
        auto nibble = [](char c) { if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            throw std::runtime_error("Invalid path encoding"); };
        out += static_cast<char>(nibble(s[i]) * 16 + nibble(s[i+1]));
    }
    if (out.find('\0') != std::string::npos) throw std::runtime_error("NUL in path");
    return out;
}
static std::string escape(const std::string& s) {
    std::string out;
    for (char c : s) switch (c) {
        case '&': out += "&amp;"; break; case '<': out += "&lt;"; break;
        case '>': out += "&gt;"; break; case '"': out += "&quot;"; break;
        default: out += c;
    }
    return out;
}
static double elapsed(Clock::time_point t) {
    return std::chrono::duration<double, std::milli>(Clock::now()-t).count();
}

class Markdown {
    std::vector<std::string> lines;
    std::vector<Label> labels;
    // Decode entities with the same parser that supplied the authoritative literal.
    static std::string entity(const std::string& value) {
        auto node = cmark_parse_document(value.data(), value.size(), CMARK_OPT_DEFAULT);
        std::string out;
        auto p = cmark_node_first_child(node);
        auto text = p ? cmark_node_first_child(p) : nullptr;
        if (text && cmark_node_get_type(text) == CMARK_NODE_TEXT) out = cmark_node_get_literal(text);
        cmark_node_free(node);
        return out;
    }
    Label label(cmark_node* node, const std::string& text, bool code = false) {
        Label result{text, {}};
        int start = cmark_node_get_start_line(node), end = cmark_node_get_end_line(node);
        std::string raw;
        std::vector<Position> positions;
        for (int n = start; n <= end && n <= static_cast<int>(lines.size()); ++n) {
            const auto& line = lines[n-1];
            size_t begin = n == start ? static_cast<size_t>(std::max(0, cmark_node_get_start_column(node)-1)) : 0;
            size_t stop = n == end ? std::min(line.size(), static_cast<size_t>(std::max(0, cmark_node_get_end_column(node)))) : line.size();
            for (size_t col = begin; col < stop; ++col) { raw += line[col]; positions.push_back({n, static_cast<int>(col)}); }
            if (n < end) { raw += '\n'; positions.push_back({n, static_cast<int>(line.size())}); }
        }
        std::string decoded;
        std::vector<Position> mapping;
        for (size_t i = 0; i < raw.size();) {
            size_t count = 1;
            std::string value(1, raw[i]);
            if (!code && raw[i] == '\\' && i+1 < raw.size() && std::ispunct(static_cast<unsigned char>(raw[i+1]))) {
                value = raw.substr(i+1,1); count = 2;
            } else if (!code && raw[i] == '&') {
                auto semicolon = raw.find(';', i);
                if (semicolon != std::string::npos && semicolon-i < 40) {
                    auto candidate = raw.substr(i, semicolon-i+1);
                    auto converted = entity(candidate);
                    if (!converted.empty() && converted != candidate) { value = converted; count = candidate.size(); }
                }
            } else if (code && raw[i] == '\n') value = " ";
            decoded += value;
            for (size_t j=0; j<value.size(); ++j) mapping.push_back(positions[i]);
            i += count;
        }
        size_t cursor = 0;
        for (unsigned char c : text) {
            auto found = decoded.find(static_cast<char>(c), cursor);
            if (found == std::string::npos) throw std::runtime_error("Cannot attribute source text at line " + std::to_string(start));
            result.positions.push_back(mapping[found]); cursor = found+1;
        }
        return result;
    }
    std::string span(Label value) {
        // litehtml can trim leading whitespace inside a new inline span, even under pre.
        // Keep boundary whitespace in the original parent to preserve baseline rendering.
        auto first = value.text.find_first_not_of(" \t\r\n");
        if (first == std::string::npos) return escape(value.text);
        auto last = value.text.find_last_not_of(" \t\r\n") + 1;
        auto prefix = escape(value.text.substr(0, first)), suffix = escape(value.text.substr(last));
        value.text = value.text.substr(first, last-first);
        value.positions = {value.positions.begin()+first, value.positions.begin()+last};
        int id = static_cast<int>(labels.size());
        auto text = escape(value.text);
        labels.push_back(std::move(value));
        return prefix + "<span data-mdview=\"" + std::to_string(id) + "\">" + text + "</span>" + suffix;
    }
    void instrument(cmark_node* parent) {
        for (auto node = cmark_node_first_child(parent); node;) {
            auto next = cmark_node_next(node);
            auto type = cmark_node_get_type(node);
            if (type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_HTML_BLOCK)
                throw std::runtime_error("Raw HTML is not supported (line " + std::to_string(cmark_node_get_start_line(node)) + ")");
            if (type == CMARK_NODE_IMAGE) {
                // Add metadata directly: wrapping an image in a span changes litehtml line height.
                std::unique_ptr<char, decltype(&std::free)> rendered(cmark_render_html(node, CMARK_OPT_UNSAFE, nullptr), &std::free);
                std::string html(rendered.get());
                auto tag = html.find("<img ");
                if (tag == std::string::npos) throw std::runtime_error("Cannot label image");
                html.insert(tag+5, "data-mdview-image=\"" + std::to_string(cmark_node_get_start_line(node)) + "\" ");
                auto replacement = cmark_node_new(CMARK_NODE_HTML_INLINE);
                cmark_node_set_literal(replacement, html.c_str());
                cmark_node_replace(node, replacement);
                cmark_node_free(node);
            } else if (type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE) {
                std::string text = cmark_node_get_literal(node);
                std::string html = span(label(node, text, type == CMARK_NODE_CODE));
                if (type == CMARK_NODE_CODE) html = "<code>" + html + "</code>";
                auto replacement = cmark_node_new(CMARK_NODE_HTML_INLINE);
                cmark_node_set_literal(replacement, html.c_str());
                if (!cmark_node_replace(node, replacement)) { cmark_node_free(replacement); throw std::runtime_error("Cannot label inline node"); }
                cmark_node_free(node);
            } else if (type == CMARK_NODE_CODE_BLOCK) {
                int length, offset; char character;
                bool fenced = cmark_node_get_fenced(node, &length, &offset, &character);
                int n = cmark_node_get_start_line(node) + (fenced ? 1 : 0);
                std::istringstream code(cmark_node_get_literal(node));
                std::string text, html = "<pre><code>";
                while (std::getline(code, text)) {
                    Label value{text, {}};
                    const auto& raw = n <= static_cast<int>(lines.size()) ? lines[n-1] : text;
                    auto begin = raw.find(text);
                    std::vector<int> columns;
                    for (size_t col=0; col<raw.size(); ++col) columns.push_back(static_cast<int>(col));
                    if (begin == std::string::npos) {
                        std::string expanded;
                        columns.clear();
                        for (size_t col=0; col<raw.size(); ++col) {
                            int count = raw[col]=='\t' ? 4-static_cast<int>(expanded.size()%4) : 1;
                            expanded.append(count, raw[col]=='\t' ? ' ' : raw[col]);
                            columns.insert(columns.end(), count, static_cast<int>(col));
                        }
                        begin=expanded.find(text);
                    }
                    if (begin == std::string::npos && !text.empty())
                        throw std::runtime_error("Cannot attribute code indentation at line " + std::to_string(n));
                    if (text.empty()) begin = 0;
                    for (size_t col=0; col<text.size(); ++col) value.positions.push_back({n, columns.at(begin+col)});
                    html += span(std::move(value)) + "\n"; ++n;
                }
                html += "</code></pre>\n";
                auto replacement = cmark_node_new(CMARK_NODE_HTML_BLOCK);
                cmark_node_set_literal(replacement, html.c_str());
                if (!cmark_node_replace(node, replacement)) { cmark_node_free(replacement); throw std::runtime_error("Cannot label code block"); }
                cmark_node_free(node);
            } else instrument(node);
            node = next;
        }
    }
public:
    std::string convert(const std::string& source, bool marked = true) {
        lines.clear(); labels.clear();
        std::istringstream stream(source);
        for (std::string line; std::getline(stream, line);) lines.push_back(line);
        cmark_gfm_core_extensions_ensure_registered();
        auto parser = cmark_parser_new(CMARK_OPT_VALIDATE_UTF8);
        for (auto name : {"table", "strikethrough", "autolink", "tasklist"})
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name));
        cmark_parser_feed(parser, source.data(), source.size());
        auto root = cmark_parser_finish(parser);
        try {
            if (marked) instrument(root);
            std::unique_ptr<char, decltype(&std::free)> rendered(cmark_render_html(root, CMARK_OPT_UNSAFE, cmark_parser_get_syntax_extensions(parser)), &std::free);
            std::string html(rendered.get());
            cmark_node_free(root); cmark_parser_free(parser);
            return html;
        } catch (...) { cmark_node_free(root); cmark_parser_free(parser); throw; }
    }
    void collect(const std::shared_ptr<litehtml::render_item>& node, int id, std::map<int,size_t>& offsets, std::vector<Fragment>& fragments, int image_line = 0) const {
        if (!node->is_visible()) return;
        if (auto own = node->src_el()->get_attr("data-mdview-image")) image_line = std::stoi(own);
        if (image_line && std::string(node->src_el()->get_tagName()) == "img")
            fragments.push_back({image_line, 0, 0, node->get_placement().y});
        if (auto own = node->src_el()->get_attr("data-mdview")) id = std::stoi(own);
        if (id >= 0 && node->src_el()->is_text()) {
            litehtml::string text; node->src_el()->get_text(text);
            const auto& value = labels.at(id);
            auto found = value.text.find(text, offsets[id]);
            if (found == std::string::npos) throw std::runtime_error("Render leaf does not match source literal");
            offsets[id] = found+text.size();
            if (text.find_first_not_of(" \t\r\n") != std::string::npos && !text.empty()) {
                auto first = value.positions.at(found), last = value.positions.at(found+text.size()-1);
                fragments.push_back({first.line, first.column, last.column, node->get_placement().y});
            }
        }
        for (const auto& child : node->children()) collect(child, id, offsets, fragments, image_line);
    }
};

static std::string document_html(const std::string& body, const std::string& css) {
    return "<!doctype html><html><head><meta charset=\"utf-8\"><style>" + css + "</style></head><body><main class=\"markdown-body\">" + body + "</main></body></html>";
}
// Do not fetch remote resources. Decode local URLs safely (the upstream adapter assumes valid %xx).
class Container : public html2png::container {
public:
    using html2png::container::container;
    cairo_surface_t* get_image(const std::string& url) override {
        if (url.find("://") != std::string::npos || url.find("data:") != std::string::npos) return nullptr;
        for (size_t i=0; i<url.size(); ++i) if (url[i]=='%') {
            if (i+2 >= url.size() || !std::isxdigit(static_cast<unsigned char>(url[i+1])) || !std::isxdigit(static_cast<unsigned char>(url[i+2]))) return nullptr;
            i += 2;
        }
        return html2png::container::get_image(url);
    }
};
int main(int argc, char** argv) {
    std::cout << std::unitbuf;
    Markdown markdown;
    if (argc == 5 && std::string(argv[1]) == "--html") {
        try { std::cout << document_html(markdown.convert(read_file(argv[2]), std::string(argv[4]) == "marked"), read_file(argv[3])); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc != 1) { std::cerr << "Usage: mdview-preview [--html markdown css plain|marked]\n"; return 2; }
    std::unique_ptr<html2png::converter> converter;
    std::unique_ptr<Container> container;
    litehtml::document::ptr doc;
    std::vector<Fragment> fragments;
    int revision = 0, width = 0;
    for (std::string request; std::getline(std::cin, request);) {
        try {
            std::istringstream input(request);
            std::string op; input >> op;
            if (op == "QUIT") break;
            if (op == "LOAD") {
                int rev=0, w=0; std::string snapshot, base, css;
                if (!(input >> rev >> w >> snapshot >> base >> css) || rev < 1 || w < 64 || w > 4096) throw std::runtime_error("Invalid LOAD request");
                auto t = Clock::now();
                auto body = markdown.convert(read_file(unhex(snapshot)));
                auto html = document_html(body, read_file(unhex(css)));
                doc.reset(); container.reset(); converter.reset(); fragments.clear();
                converter = std::make_unique<html2png::converter>(w, 800, 96.0, "sans-serif");
                container = std::make_unique<Container>(unhex(base), converter.get());
                doc = litehtml::document::createFromString(html, container.get());
                if (!doc) throw std::runtime_error("Cannot create layout");
                doc->render(w);
                std::map<int,size_t> offsets;
                markdown.collect(doc->root_render(), -1, offsets, fragments);
                revision = rev; width = w;
                for (const auto& f : fragments) std::cout << "FRAG " << f.line << ' ' << f.column << ' ' << f.end << ' ' << f.y << '\n';
                std::cout << "READY " << revision << ' ' << width << ' ' << doc->height() << ' ' << elapsed(t) << '\n';
            } else if (op == "DRAW") {
                int rev=0, seq=0, line=0, col=0, botline=0, height=0; std::string output;
                if (!(input >> rev >> seq >> line >> col >> botline >> height >> output) || rev != revision || !doc || line < 0 || col < 0 || height < 1 || height > 8192) throw std::runtime_error("Invalid DRAW request");
                int top = 0;
                if (line == 0) {
                    top = std::max(0, col);
                } else if (line > 1) {
                    double y=0; int preceding=0, following=0; const Fragment* selected=nullptr;
                    for (const auto& f : fragments) {
                        if (f.line <= line && f.line > preceding) preceding = f.line;
                        if (f.line > line && (!following || f.line < following)) following = f.line;
                        if (f.line != line) continue;
                        if (!selected || (f.column <= col && f.column > selected->column)) selected = &f;
                    }
                    if (selected) y = selected->y;
                    else if (following) {
                        y = doc->height();
                        for (const auto& f : fragments) if (f.line == following) y = std::min(y, f.y);
                    } else if (preceding) {
                        y = 0;
                        for (const auto& f : fragments) if (f.line == preceding) y = std::max(y, f.y);
                    }
                    top = std::max(0, static_cast<int>(std::floor(y)));
                }
                auto t = Clock::now();
                auto surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
                if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(surface); throw std::runtime_error("Cannot allocate viewport"); }
                auto cr = cairo_create(surface);
                cairo_set_source_rgb(cr, 13/255.0, 17/255.0, 23/255.0); cairo_paint(cr);
                int clip_height = height;
                if (botline > 0) {
                    double max_y = 0;
                    bool found = false;
                    for (const auto& f : fragments) {
                        if (f.line <= botline) {
                            max_y = std::max(max_y, f.y);
                            found = true;
                        }
                    }
                    if (found && max_y + 36.0 > top) {
                        clip_height = std::min(height, static_cast<int>(std::ceil(max_y + 36.0 - top)));
                    }
                }
                litehtml::position clip(0, 0, width, clip_height);
                doc->draw(reinterpret_cast<litehtml::uint_ptr>(cr), 0, -top, &clip);
                auto draw_status = cairo_status(cr);
                cairo_destroy(cr);
                auto out_path = unhex(output);
                bool saved = false;
                if (out_path.size() >= 5 && out_path.substr(out_path.size() - 5) == ".rgba") {
                    cairo_surface_flush(surface);
                    const auto* data = cairo_image_surface_get_data(surface);
                    int stride = cairo_image_surface_get_stride(surface);
                    std::vector<unsigned char> rgba(static_cast<size_t>(width) * height * 4);
                    for (int y = 0; y < height; ++y) {
                        const auto* row = reinterpret_cast<const uint32_t*>(data + y * stride);
                        for (int x = 0; x < width; ++x) {
                            uint32_t p = row[x]; unsigned a = p >> 24;
                            auto* out = &rgba[(static_cast<size_t>(y) * width + x) * 4];
                            for (int c = 0; c < 3; ++c) {
                                unsigned v = (p >> (16 - c * 8)) & 255;
                                out[c] = a == 255 ? v : (a ? std::min(255u, (v * 255 + a / 2) / a) : 0);
                            }
                            out[3] = a;
                        }
                    }
                    std::ofstream file(out_path, std::ios::binary);
                    file.write(reinterpret_cast<const char*>(rgba.data()), rgba.size());
                    saved = static_cast<bool>(file);
                } else {
                    // Frames are transient: favor encode latency over maximum PNG compression.
                    auto pixbuf = gdk_pixbuf_get_from_surface(surface, 0, 0, width, height);
                    saved = pixbuf && gdk_pixbuf_save(pixbuf, out_path.c_str(), "png", nullptr, "compression", "1", nullptr);
                    if (pixbuf) g_object_unref(pixbuf);
                }
                cairo_surface_destroy(surface);
                if (!saved || draw_status != CAIRO_STATUS_SUCCESS) throw std::runtime_error("Cannot write viewport PNG");
                std::cout << "FRAME " << rev << ' ' << seq << ' ' << line << ' ' << col << ' ' << top << ' ' << width << ' ' << height << ' ' << elapsed(t) << '\n';
            } else throw std::runtime_error("Unknown request");
        } catch (const std::exception& e) { std::cout << "ERROR " << hex(e.what()) << '\n'; }
    }
}
