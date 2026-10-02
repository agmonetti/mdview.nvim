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
#include <cstdlib>
#include <cmark-gfm.h>
#include <cmark-gfm-core-extensions.h>
#include <litehtml/render_item.h>

#include "octicons.hpp"
using Clock = std::chrono::steady_clock;
struct Position { int line, column; };
struct Label { std::string text; std::vector<Position> positions; };
struct Fragment { int line, column, end; double y; double block_bottom = 0; double bottom = 0; };
struct Detail { int start, end = 0, header = 0; bool open = true; int parent = -1; litehtml::position box; bool visible = false, title = false; };
static std::vector<std::pair<Position, Position>> html_comments;
static int html_root_label = -1;
static const Fragment* source_fragment(const std::vector<Fragment>& fragments, const std::vector<Detail>& details, int line, int col) {
    for (const auto& detail : details) {
        if (!detail.visible || detail.open || line <= detail.header || line > detail.end) continue;
        bool hidden_by_parent = false;
        for (int parent = detail.parent; parent >= 0; parent = details[parent].parent)
            if (!details[parent].open) hidden_by_parent = true;
        if (hidden_by_parent) continue;
        for (const auto& fragment : fragments)
            if (fragment.line == detail.header && fragment.y == detail.box.y) return &fragment;
    }
    auto less = [](Position a, Position b) { return a.line < b.line || (a.line == b.line && a.column < b.column); };
    const Position query{line, col};
    for (const auto& range : html_comments) {
        if (less(query, range.first) || less(range.second, query)) continue;
        const Fragment *next = nullptr, *previous = nullptr;
        for (const auto& fragment : fragments) {
            const Position position{fragment.line, fragment.column};
            if (less(range.second, position)) {
                if (!next || less(position, {next->line, next->column})) next = &fragment;
            } else if (less(position, range.first)) {
                if (!previous || less({previous->line, previous->column}, position)) previous = &fragment;
            }
        }
        return next ? next : previous;
    }
    const Fragment *selected=nullptr, *preceding=nullptr, *following=nullptr;
    for (const auto& f : fragments) {
        if (f.line < line && (!preceding || f.line > preceding->line || (f.line == preceding->line && f.y > preceding->y))) preceding = &f;
        if (f.line > line && (!following || f.line < following->line || (f.line == following->line && f.y < following->y))) following = &f;
        if (f.line == line && (!selected || (f.column <= col && f.column > selected->column))) selected = &f;
    }
    return selected ? selected : (following ? following : preceding);
}
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
#include "mermaid.hpp"
#include "html_images.hpp"

class Markdown {
    std::vector<std::string> lines;
    std::vector<Label> labels;
    std::vector<Detail> details;
    MermaidRenderer* mermaid = nullptr;
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
    Label original_label(cmark_node* node, const std::string& text, bool code = false) {
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
    #include "html_subset.hpp"
    struct Alert {
        int first, last, column, paragraph_last;
        const char* type;
        const char* title;
    };
    std::vector<Alert> find_alerts(cmark_node* root) const {
        std::vector<Alert> result;
        struct Spec { const char* marker; const char* type; const char* title; };
        static constexpr Spec specs[] = {
            {"[!NOTE]", "note", "Note"}, {"[!TIP]", "tip", "Tip"}, {"[!IMPORTANT]", "important", "Important"},
            {"[!WARNING]", "warning", "Warning"}, {"[!CAUTION]", "caution", "Caution"}
        };
        for (auto quote = cmark_node_first_child(root); quote; quote = cmark_node_next(quote)) {
            if (cmark_node_get_type(quote) != CMARK_NODE_BLOCK_QUOTE) continue;
            const int first = cmark_node_get_start_line(quote);
            if (first < 1 || first > static_cast<int>(lines.size())) continue;
            const auto& line = lines[first-1];
            size_t column = line.find_first_not_of(" ");
            if (column == std::string::npos || column > 3 || line[column] != '>') continue;
            ++column;
            if (column < line.size() && (line[column] == ' ' || line[column] == '\t')) ++column;
            auto end = line.find_last_not_of(" \t\r");
            if (end == std::string::npos || end < column) continue;
            for (const auto& spec : specs) {
                if (line.compare(column, end-column+1, spec.marker) == 0) {
                    auto first_block = cmark_node_first_child(quote);
                    const int paragraph_last = first_block && cmark_node_get_type(first_block) == CMARK_NODE_PARAGRAPH
                        ? cmark_node_get_end_line(first_block) : 0;
                    result.push_back({first, cmark_node_get_end_line(quote), static_cast<int>(column), paragraph_last,
                                      spec.type, spec.title});
                    break;
                }
            }
        }
        return result;
    }
    static void reject_html(cmark_node* parent) {
        for (auto node = cmark_node_first_child(parent); node; node = cmark_node_next(node)) {
            auto type = cmark_node_get_type(node);
            if (type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_HTML_BLOCK)
                throw std::runtime_error("Raw HTML is not supported (line " + std::to_string(cmark_node_get_start_line(node)) + ")");
            reject_html(node);
        }
    }
    void render_alerts(cmark_node* root, const std::vector<Alert>& alerts, bool marked) {
        auto node = cmark_node_first_child(root);
        for (const auto& alert : alerts) {
            while (node && cmark_node_get_end_line(node) < alert.first) node = cmark_node_next(node);
            auto wrapper = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK);
            std::string title = alert.title;
            if (marked) {
                Label value{title, std::vector<Position>(title.size(), {alert.first, alert.column})};
                title = span(std::move(value));
            }
            const auto enter = "<div class=\"mdview-alert mdview-alert-" + std::string(alert.type)
                + "\">\n<p class=\"mdview-alert-title\"><mdview-alert-icon class=\"mdview-alert-icon\" kind=\""
                + alert.type + "\" aria-hidden=\"true\"></mdview-alert-icon>"
                + title + "</p>\n";
            cmark_node_set_on_enter(wrapper, enter.c_str());
            cmark_node_set_on_exit(wrapper, "</div>\n");
            if (!(node ? cmark_node_insert_before(node, wrapper) : cmark_node_append_child(root, wrapper))) {
                cmark_node_free(wrapper);
                throw std::runtime_error("Cannot insert alert");
            }
            // Masked marker lines can leave an empty quote or turn a lazy
            // continuation into document children. Retain their original nodes
            // and source coordinates, bounded by the original quote's extent.
            cmark_node* continued = nullptr;
            int continued_last = 0;
            auto retain = [&](cmark_node* child) {
                cmark_node_unlink(child);
                const bool continuation = cmark_node_get_type(child) == CMARK_NODE_PARAGRAPH
                    && cmark_node_get_end_line(child) <= alert.paragraph_last;
                if (continuation && continued) {
                    // A masked empty first line breaks lazy continuation at the
                    // document level; restore its original paragraph grouping.
                    const auto& previous = lines[continued_last-1];
                    const auto end = previous.size() - (!previous.empty() && previous.back() == '\r' ? 1 : 0);
                    const bool spaces = end >= 2 && previous[end-1] == ' ' && previous[end-2] == ' ';
                    size_t backslashes = 0;
                    while (backslashes < end && previous[end-backslashes-1] == '\\') ++backslashes;
                    const bool escaped_break = backslashes % 2 != 0;
                    if (escaped_break) {
                        auto last = cmark_node_last_child(continued);
                        if (last && cmark_node_get_type(last) == CMARK_NODE_TEXT) {
                            std::string text = cmark_node_get_literal(last);
                            if (!text.empty() && text.back() == '\\') {
                                text.pop_back();
                                cmark_node_set_literal(last, text.c_str());
                            }
                        }
                    }
                    auto separator = cmark_node_new(spaces || escaped_break ? CMARK_NODE_LINEBREAK : CMARK_NODE_SOFTBREAK);
                    cmark_node_append_child(continued, separator);
                    continued_last = cmark_node_get_end_line(child);
                    while (auto inline_node = cmark_node_first_child(child)) {
                        cmark_node_unlink(inline_node);
                        cmark_node_append_child(continued, inline_node);
                    }
                    cmark_node_free(child);
                } else {
                    if (!cmark_node_append_child(wrapper, child)) {
                        cmark_node_free(child);
                        throw std::runtime_error("Cannot retain alert body");
                    }
                    if (continuation) {
                        continued = child;
                        continued_last = cmark_node_get_end_line(child);
                    }
                }
            };
            while (node && cmark_node_get_start_line(node) <= alert.last) {
                auto next = cmark_node_next(node);
                if (cmark_node_get_type(node) == CMARK_NODE_BLOCK_QUOTE) {
                    while (auto child = cmark_node_first_child(node)) {
                        retain(child);
                    }
                    cmark_node_unlink(node);
                    cmark_node_free(node);
                } else {
                    retain(node);
                }
                node = next;
            }
        }
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
                std::string html;
                if (type == CMARK_NODE_CODE) {
                    // A nested span changes inline-code wrap geometry. Label the original code element.
                    const auto id = labels.size();
                    labels.push_back(label(node, text, true));
                    html = "<code data-mdview=\"" + std::to_string(id) + "\">" + escape(text) + "</code>";
                } else html = html_bare_text.count(node) ? escape(text) : span(label(node, text));
                auto replacement = cmark_node_new(CMARK_NODE_HTML_INLINE);
                cmark_node_set_literal(replacement, html.c_str());
                if (!cmark_node_replace(node, replacement)) { cmark_node_free(replacement); throw std::runtime_error("Cannot label inline node"); }
                cmark_node_free(node);
            } else if (type == CMARK_NODE_CODE_BLOCK) {
                int length, offset; char character;
                bool fenced = cmark_node_get_fenced(node, &length, &offset, &character);
                std::istringstream info(cmark_node_get_fence_info(node));
                std::string language; info >> language;
                if (fenced && language == "mermaid" && mermaid && mermaid->enabled()) {
                    const int first = cmark_node_get_start_line(node), last = cmark_node_get_end_line(node);
                    auto png = mermaid->render(cmark_node_get_literal(node), first);
                    if (png) {
                        auto html = "<p><img data-mdview-mermaid=\"" + std::to_string(first)
                            + "\" data-mdview-mermaid-end=\"" + std::to_string(last)
                            + "\" src=\"" + escape(*png) + "\" alt=\"Mermaid diagram\" style=\"max-width:100%;height:auto\"></p>\n";
                        auto replacement = cmark_node_new(CMARK_NODE_HTML_BLOCK);
                        cmark_node_set_literal(replacement, html.c_str());
                        if (!cmark_node_replace(node, replacement)) { cmark_node_free(replacement); throw std::runtime_error("Cannot insert Mermaid diagram"); }
                        cmark_node_free(node);
                        node = next;
                        continue;
                    }
                }
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
    std::vector<Detail>& get_details() { return details; }
    std::string convert(const std::string& source, bool marked = true, MermaidRenderer* renderer = nullptr, bool alerts = false, bool html_enabled = true) {
        lines.clear(); labels.clear(); details.clear(); html_comments.clear(); html_root_label = -1; mermaid = renderer;
        std::istringstream stream(source);
        for (std::string line; std::getline(stream, line);) lines.push_back(line);
        cmark_gfm_core_extensions_ensure_registered();
        auto parse = [](const std::string& text) {
            auto parser = cmark_parser_new(CMARK_OPT_VALIDATE_UTF8);
            for (auto name : {"table", "strikethrough", "autolink", "tasklist"})
                cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name));
            cmark_parser_feed(parser, text.data(), text.size());
            return parser;
        };
        auto parser = parse(source);
        auto root = cmark_parser_finish(parser);
        try {
            if (!html_enabled) reject_html(root);
            if (alerts) {
                const auto found = find_alerts(root);
                std::string protected_source;
                size_t offset = 0;
                int line = 1;
                for (const auto& alert : found) {
                    if (protected_source.empty()) protected_source = source;
                    while (line < alert.first) {
                        offset += lines[line-1].size() + 1;
                        ++line;
                    }
                    std::fill_n(protected_source.begin() + offset + alert.column,
                                std::char_traits<char>::length(alert.type) + 3, ' ');
                }
                if (!protected_source.empty()) {
                    cmark_node_free(root);
                    cmark_parser_free(parser);
                    parser = parse(protected_source);
                    root = cmark_parser_finish(parser);
                }
                render_alerts(root, found, marked);
            }
            if (html_enabled) sanitize_html(root, marked);
            if (marked) instrument(root);
            std::unique_ptr<char, decltype(&std::free)> rendered(cmark_render_html(root, CMARK_OPT_UNSAFE, cmark_parser_get_syntax_extensions(parser)), &std::free);
            std::string html = html_annotate(rendered.get());
            cmark_node_free(root); cmark_parser_free(parser);
            return html;
        } catch (...) { cmark_node_free(root); cmark_parser_free(parser); throw; }
    }
    void collect(const std::shared_ptr<litehtml::render_item>& node, int id, std::map<int,size_t>& offsets, std::vector<Fragment>& fragments, int image_line = 0) {
        if (!node->is_visible()) return;
        // The generated disclosure glyph has no source bytes to attribute.
        if (node->src_el()->get_attr("data-mdview-detail-indicator")) return;
        if (auto own = node->src_el()->get_attr("data-mdview-detail")) {
            auto& detail = details.at(std::stoi(own));
            detail.box = node->get_placement();
            detail.visible = true;
            const double y = detail.box.y, bottom = detail.box.y + detail.box.height;
            fragments.push_back({detail.start, 0, 0, y, 0, bottom});
            fragments.push_back({detail.header, 0, 0, y, 0, bottom});
            if (!detail.open) for (int line = detail.header+1; line <= detail.end; ++line)
                fragments.push_back({line, 0, 0, y, 0, bottom});
        }
        if (auto own = node->src_el()->get_attr("data-mdview-break")) {
            const auto placement = node->get_placement();
            const int line = std::stoi(own), column = std::stoi(node->src_el()->get_attr("data-mdview-break-column"));
            fragments.push_back({line, column, column, placement.y, 0, static_cast<double>(placement.y + placement.height)});
        }
        if (auto own = node->src_el()->get_attr("data-mdview-image")) image_line = std::stoi(own);
        if (image_line && std::string(node->src_el()->get_tagName()) == "img") {
            const auto placement = node->get_placement();
            const auto column = node->src_el()->get_attr("data-mdview-image-column");
            const auto end = node->src_el()->get_attr("data-mdview-image-end");
            const auto end_line = node->src_el()->get_attr("data-mdview-image-end-line");
            const int last = end_line ? std::stoi(end_line) : image_line;
            for (int line = image_line; line <= last; ++line) {
                const int first_column = line == image_line && column ? std::stoi(column) : 0;
                const int last_column = line == last && end ? std::stoi(end) : 0;
                fragments.push_back({line, first_column, last_column, placement.y, 0,
                    static_cast<double>(placement.y + placement.height)});
            }
        }
        if (auto first = node->src_el()->get_attr("data-mdview-mermaid")) {
            const int start = std::stoi(first), end = std::stoi(node->src_el()->get_attr("data-mdview-mermaid-end"));
            const auto placement = node->get_placement();
            for (int line = start; line <= end; ++line) fragments.push_back({line, 0, 0, placement.y, static_cast<double>(placement.y + placement.height)});
        }
        if (auto own = node->src_el()->get_attr("data-mdview")) id = std::stoi(own);
        if (id >= 0 && node->src_el()->is_text()) {
            litehtml::string text; node->src_el()->get_text(text);
            if (text.find_first_not_of(" \t\r\n") == std::string::npos) return;
            const auto& value = labels.at(id);
            auto found = value.text.find(text, offsets[id]);
            if (found == std::string::npos) throw std::runtime_error("Render leaf does not match source literal");
            offsets[id] = found+text.size();
            if (text.find_first_not_of(" \t\r\n") != std::string::npos && !text.empty()) {
                auto first = value.positions.at(found), last = value.positions.at(found+text.size()-1);
                const auto placement = node->get_placement();
                fragments.push_back({first.line, first.column, last.column, placement.y, 0, static_cast<double>(placement.y + placement.height)});
            }
        }
        for (const auto& child : node->children()) collect(child, id, offsets, fragments, image_line);
    }
};

static std::string document_html(const std::string& body, const std::string& css) {
    const auto metadata = html_root_label < 0 ? std::string() : " data-mdview=\"" + std::to_string(html_root_label) + "\"";
    return "<!doctype html><html><head><meta charset=\"utf-8\"><style>" + css + "</style></head><body><main class=\"markdown-body\"" + metadata + ">" + body + "</main></body></html>";
}
static std::string details_html(std::string html, const std::vector<Detail>& details) {
    for (size_t id = 0; id < details.size(); ++id) {
        if (!details[id].end || details[id].open) continue;
        const auto key = std::to_string(id);
        const auto indicator = "data-mdview-detail-indicator=\"" + key + "\">▾";
        const auto body = "data-mdview-detail-body=\"" + key + "\">";
        auto index = html.find(indicator);
        if (index == std::string::npos) throw std::runtime_error("Cannot locate detail indicator");
        html.replace(index, indicator.size(), "data-mdview-detail-indicator=\"" + key + "\">▸");
        index = html.find(body);
        if (index == std::string::npos) throw std::runtime_error("Cannot locate detail body");
        html.replace(index, body.size(), "data-mdview-detail-body=\"" + key + "\" style=\"display:none\">");
    }
    return html;
}
static void emit_geometry(const std::vector<Fragment>& fragments, const std::vector<Detail>& details) {
    for (const auto& f : fragments) std::cout << "FRAG " << f.line << ' ' << f.column << ' ' << f.end << ' ' << f.y << '\n';
    for (size_t id = 0; id < details.size(); ++id) {
        const auto& detail = details[id];
        if (!detail.end) continue;
        const auto& box = detail.box;
        std::cout << "DETAIL " << id << ' ' << detail.start << ' ' << detail.end << ' '
            << (detail.visible ? box.x : 0) << ' ' << (detail.visible ? box.y : 0) << ' '
            << (detail.visible ? box.width : 0) << ' ' << (detail.visible ? box.height : 0) << ' '
            << detail.open << '\n';
    }
}
// Do not fetch remote resources. Decode local URLs safely (the upstream adapter assumes valid %xx).
class Container : public mdview::OcticonContainer {
    const MermaidRenderer* mermaid;
public:
    Container(const std::string& base, html2png::converter* converter, const MermaidRenderer* renderer)
        : mdview::OcticonContainer(base, converter), mermaid(renderer) {}
    cairo_surface_t* get_image(const std::string& url) override {
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
    }
};
int main(int argc, char** argv) {
    std::cout << std::unitbuf;
    Markdown markdown;
    if ((argc == 5 || (argc == 6 && (std::string(argv[5]) == "alerts" || std::string(argv[5]) == "html=0"))) && std::string(argv[1]) == "--html") {
        try {
            const bool alerts = argc == 6 && std::string(argv[5]) == "alerts";
            const bool html_enabled = !(argc == 6 && std::string(argv[5]) == "html=0");
            html_images::configure(std::filesystem::path(argv[2]).parent_path().string(), argv[2]);
            const auto body = markdown.convert(read_file(argv[2]), std::string(argv[4]) == "marked", nullptr, alerts, html_enabled);
            std::cout << document_html(body, read_file(argv[3]));
            return 0;
        }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc != 1) { std::cerr << "Usage: mdview-preview [--html markdown css plain|marked [alerts|html=0]]\n"; return 2; }
    install_mermaid_cleanup();
    MermaidRenderer mermaid;
    std::unique_ptr<html2png::converter> converter;
    std::unique_ptr<Container> container;
    litehtml::document::ptr doc;
    std::vector<Fragment> fragments;
    std::string layout_html, base_path;
    int revision = 0, width = 0;
    for (std::string request; std::getline(std::cin, request);) {
        try {
            std::istringstream input(request);
            std::string op; input >> op;
            if (op == "QUIT") break;
            if (op == "LOAD") {
                doc.reset(); container.reset(); converter.reset(); fragments.clear(); revision = 0; width = 0;
                html_images::clear();
                mermaid.clear();
                int rev=0, w=0; std::string snapshot, base, css;
                if (!(input >> rev >> w >> snapshot >> base >> css) || rev < 1 || w < 64 || w > 4096) throw std::runtime_error("Invalid LOAD request");
                bool alerts = false, html_enabled = true;
                std::string executable, option, diagrams, background, extra;
                while (input >> option) {
                    if (option == "alerts=1") alerts = true;
                    else if (option == "html=0") html_enabled = false;
                    else { executable = option; break; }
                }
                if (!executable.empty()) {
                    if (!(input >> diagrams >> background) || input >> extra) throw std::runtime_error("Invalid Mermaid LOAD options");
                    const auto expected = std::filesystem::path(unhex(snapshot)).parent_path() / "diagrams";
                    if (std::filesystem::path(unhex(diagrams)).lexically_normal() != expected.lexically_normal())
                        throw std::runtime_error("Mermaid artifacts must stay beside the session snapshot");
                    mermaid.configure(unhex(executable), unhex(diagrams), unhex(background), w);
                }
                auto t = Clock::now();
                html_images::configure(unhex(base), unhex(snapshot));
                auto body = markdown.convert(read_file(unhex(snapshot)), true, &mermaid, alerts, html_enabled);
                layout_html = document_html(body, read_file(unhex(css)));
                base_path = unhex(base);
                converter = std::make_unique<html2png::converter>(w, 800, 96.0, "sans-serif");
                container = std::make_unique<Container>(base_path, converter.get(), &mermaid);
                doc = litehtml::document::createFromString(layout_html, container.get());
                if (!doc) throw std::runtime_error("Cannot create layout");
                doc->render(w);
                html_images::context.decoding = false;
                std::map<int,size_t> offsets;
                for (auto& detail : markdown.get_details()) detail.visible = false;
                markdown.collect(doc->root_render(), -1, offsets, fragments);
                revision = rev; width = w;
                emit_geometry(fragments, markdown.get_details());
                std::cout << "READY " << revision << ' ' << width << ' ' << doc->height() << ' ' << elapsed(t) << '\n';
            } else if (op == "TOGGLE") {
                int rev = 0, id = -1, open = -1;
                std::string extra;
                if (!(input >> rev >> id >> open) || input >> extra || !doc || rev <= revision
                    || id < 0 || id >= static_cast<int>(markdown.get_details().size())
                    || !markdown.get_details()[id].end || (open != 0 && open != 1))
                    throw std::runtime_error("Invalid TOGGLE request");
                auto t = Clock::now();
                markdown.get_details()[id].open = open;
                auto next = litehtml::document::createFromString(details_html(layout_html, markdown.get_details()), container.get());
                if (!next) throw std::runtime_error("Cannot create detail layout");
                next->render(width);
                std::vector<Fragment> next_fragments;
                std::map<int,size_t> offsets;
                for (auto& detail : markdown.get_details()) detail.visible = false;
                markdown.collect(next->root_render(), -1, offsets, next_fragments);
                doc = std::move(next);
                fragments = std::move(next_fragments);
                revision = rev;
                emit_geometry(fragments, markdown.get_details());
                std::cout << "READY " << revision << ' ' << width << ' ' << doc->height() << ' ' << elapsed(t) << '\n';
            } else if (op == "DRAW") {
                int rev=0, seq=0, line=0, col=0, botline=0, height=0; std::string output;
                if (!(input >> rev >> seq >> line >> col >> botline >> height >> output) || rev != revision || !doc || line < 0 || col < 0 || height < 1 || height > 8192) throw std::runtime_error("Invalid DRAW request");
                int cursor_line=0, cursor_col=0, through_line=0, previous_top=-1, selected=-1;
                std::vector<int> tail;
                std::string value;
                while (input >> value) {
                    std::istringstream number(value);
                    int n; char rest;
                    if (!(number >> n) || number >> rest) throw std::runtime_error("Invalid DRAW options");
                    tail.push_back(n);
                }
                const bool reveal = tail.size() == 4 || tail.size() == 5;
                if (tail.size() != 0 && tail.size() != 1 && !reveal) throw std::runtime_error("Invalid DRAW options");
                if (reveal) {
                    cursor_line = tail[0]; cursor_col = tail[1]; through_line = tail[2]; previous_top = tail[3];
                    if (cursor_line < 0 || cursor_col < 0 || through_line < cursor_line || previous_top < -1)
                        throw std::runtime_error("Invalid cursor reveal request");
                }
                if (tail.size() == 1 || tail.size() == 5) selected = tail.back();
                if (selected < -1 || selected >= static_cast<int>(markdown.get_details().size()))
                    throw std::runtime_error("Invalid selected detail");
                int top = 0;
                if (line == 0) {
                    top = std::max(0, col);
                } else if (line > 1) {
                    if (const auto* f = source_fragment(fragments, markdown.get_details(), line, col))
                        top = std::max(0, static_cast<int>(std::floor(f->y)));
                }
                if (reveal) {
                    if (previous_top >= 0) top = previous_top;
                    if (cursor_line > 0) {
                        if (const auto* active = source_fragment(fragments, markdown.get_details(), cursor_line, cursor_col)) {
                            double first = active->y;
                            double last = std::max({first, active->bottom, active->block_bottom});
                            if (through_line > cursor_line) {
                                if (const auto* end = source_fragment(fragments, markdown.get_details(), through_line, 0)) {
                                    last = std::max({last, end->y, end->bottom, end->block_bottom});
                                    // Prefer the diagram if heading + graph cannot fit together.
                                    if (end->block_bottom > 0 && std::ceil(last) - std::floor(first) > height) first = end->y;
                                }
                            }
                            const int begin = static_cast<int>(std::floor(first));
                            const int end = static_cast<int>(std::ceil(last));
                            if (end - begin > height) {
                                // A tall diagram has no relation-level navigation: retain its start.
                                top = begin;
                            } else if (begin < top) top = begin;
                            else if (end > top + height) top = end - height;
                        }
                    }
                    top = std::max(0, std::min(top, std::max(0, static_cast<int>(std::ceil(doc->height())) - height)));
                }
                auto t = Clock::now();
                auto surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
                if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(surface); throw std::runtime_error("Cannot allocate viewport"); }
                auto cr = cairo_create(surface);
                cairo_set_source_rgb(cr, 13/255.0, 17/255.0, 23/255.0); cairo_paint(cr);
                int clip_height = height;
                if (botline > 0 && !reveal) {
                    double max_y = 0;
                    bool found = false;
                    for (const auto& f : fragments) {
                        if (f.line <= botline) {
                            max_y = std::max(max_y, std::max(f.y, f.block_bottom));
                            found = true;
                        }
                    }
                    if (found && max_y + 36.0 > top) {
                        clip_height = std::min(height, static_cast<int>(std::ceil(max_y + 36.0 - top)));
                    }
                }
                litehtml::position clip(0, 0, width, clip_height);
                doc->draw(reinterpret_cast<litehtml::uint_ptr>(cr), 0, -top, &clip);
                if (selected >= 0 && markdown.get_details()[selected].visible) {
                    const auto& box = markdown.get_details()[selected].box;
                    cairo_save(cr);
                    cairo_rectangle(cr, 0, 0, width, clip_height);
                    cairo_clip(cr);
                    cairo_rectangle(cr, box.x, box.y - top, box.width, box.height);
                    cairo_set_source_rgba(cr, 0.35, 0.65, 1.0, 0.16);
                    cairo_fill_preserve(cr);
                    cairo_set_source_rgba(cr, 0.35, 0.65, 1.0, 0.9);
                    cairo_set_line_width(cr, 2.0);
                    cairo_stroke(cr);
                    cairo_restore(cr);
                }
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
        } catch (const std::exception& e) {
            doc.reset(); container.reset(); converter.reset(); fragments.clear(); revision = 0; width = 0;
            html_images::clear();
            mermaid.clear();
            std::cout << "ERROR " << hex(e.what()) << '\n';
        }
    }
}
