// Experimental Markdown members, included only by the generated preview copy.
// Every HTML byte comes from a cmark raw node; generated Markdown HTML never enters this parser.
struct HtmlToken {
    enum Kind { text, tag, comment } kind = text;
    size_t begin = 0, end = 0;
    std::string name;
    std::string src, alt, image_error;
    bool has_src = false;
    bool closing = false, self = false, valid = true;
    int group = -1;
};
struct HtmlRaw {
    cmark_node* node;
    std::string literal;
    std::vector<Position> positions;
    std::vector<HtmlToken> tokens;
    bool block;
};
struct HtmlGroup { bool valid = true; Position start{1, 0}; std::string reason; };
static bool html_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'; }
static bool html_letter(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static bool html_allowed(const std::string& name) {
    return name == "br" || name == "img" || name == "kbd" || name == "sup" || name == "sub" || name == "span" || name == "p" || name == "div";
}
static std::string html_attribute(const std::string& value) {
    std::string out;
    for (size_t i = 0; i < value.size();) {
        if (value[i] == '&') {
            const auto end = value.find(';', i+1);
            if (end != std::string::npos && end-i < 40) {
                const auto candidate = value.substr(i, end-i+1);
                const auto decoded = entity(candidate);
                if (!decoded.empty() && decoded != candidate) { out += decoded; i = end+1; continue; }
            }
        }
        out += value[i++];
    }
    return out;
}
static HtmlToken html_tag(const std::string& raw, size_t begin) {
    HtmlToken token; token.kind = HtmlToken::tag; token.begin = begin;
    size_t i = begin + 1;
    if (i < raw.size() && raw[i] == '/') { token.closing = true; ++i; }
    const size_t name = i;
    if (i < raw.size() && html_letter(raw[i])) {
        while (i < raw.size() && (html_letter(raw[i]) || (raw[i] >= '0' && raw[i] <= '9') || raw[i] == '-')) ++i;
    }
    token.name = raw.substr(name, i-name);
    for (char& c : token.name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    token.valid = !token.name.empty() && html_allowed(token.name);
    bool separated = false;
    std::map<std::string, bool> attributes;
    while (i < raw.size()) {
        if (html_space(raw[i])) { separated = true; ++i; continue; }
        if (raw[i] == '>') { token.end = i+1; return token; }
        if (raw[i] == '/' && i+1 < raw.size() && raw[i+1] == '>') {
            token.self = true; token.valid = token.valid && !token.closing && (token.name == "br" || token.name == "img");
            token.end = i+2; return token;
        }
        if (!separated || token.closing) token.valid = false;
        separated = false;
        const size_t attr = i;
        while (i < raw.size() && !html_space(raw[i]) && raw[i] != '=' && raw[i] != '/' && raw[i] != '>' && raw[i] != '<' && raw[i] != '\'' && raw[i] != '"' && raw[i] != '`') ++i;
        if (i == attr) { token.valid = false; ++i; continue; }
        std::string attribute = raw.substr(attr, i-attr), value;
        for (char& c : attribute) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (token.name == "img" && !attributes.emplace(attribute, true).second) token.valid = false;
        bool has_value = false;
        bool space_after = false;
        while (i < raw.size() && html_space(raw[i])) { space_after = true; ++i; }
        if (i < raw.size() && raw[i] == '=') {
            ++i;
            has_value = true;
            while (i < raw.size() && html_space(raw[i])) ++i;
            if (i < raw.size() && (raw[i] == '\'' || raw[i] == '"')) {
                char quote = raw[i++];
                const size_t start = i;
                while (i < raw.size() && raw[i] != quote) ++i;
                if (i == raw.size()) { token.valid = false; break; }
                value = raw.substr(start, i-start);
                ++i;
            } else {
                const size_t start = i;
                while (i < raw.size() && !html_space(raw[i]) && raw[i] != '>') {
                    if (raw[i] == '<' || raw[i] == '=' || raw[i] == '\'' || raw[i] == '"' || raw[i] == '`') token.valid = false;
                    ++i;
                }
                if (i == start) token.valid = false;
                value = raw.substr(start, i-start);
            }
        } else separated = space_after;
        if (token.name == "img" && (attribute == "src" || attribute == "alt")) {
            if (!has_value) token.valid = false;
            if (attribute == "src") { token.src = html_attribute(value); token.has_src = has_value; }
            else token.alt = html_attribute(value);
        }
    }
    token.valid = false; token.end = raw.size(); return token;
}
std::map<cmark_node*, std::pair<Position, Position>> html_bounds;
std::map<cmark_node*, std::vector<Position>> html_raw_positions;
// A cmark inline HTML token consumes literal newlines without updating the
// inline subject's line counter. Project that subject's coordinates onto the
// original bytes; do not locate later text by its value.
void html_prepare_positions(cmark_node* root) {
    html_bounds.clear(); html_raw_positions.clear();
    auto blocks = [&](auto&& self, cmark_node* parent) -> void {
        for (auto block = cmark_node_first_child(parent); block; block = cmark_node_next(block)) {
            const auto type = cmark_node_get_type(block);
            if (type != CMARK_NODE_PARAGRAPH && type != CMARK_NODE_HEADING
                && std::string(cmark_node_get_type_string(block)) != "table_cell") { self(self, block); continue; }
            std::vector<cmark_node*> nodes, raws;
            auto leaves = [&](auto&& walk, cmark_node* node) -> void {
                for (auto child = cmark_node_first_child(node); child; child = cmark_node_next(child)) {
                    nodes.push_back(child);
                    if (cmark_node_get_type(child) == CMARK_NODE_HTML_INLINE) raws.push_back(child);
                    walk(walk, child);
                }
            };
            leaves(leaves, block);
            if (raws.empty()) continue;
            std::map<std::pair<int,int>, Position> projection;
            const int first = cmark_node_get_start_line(block), last = cmark_node_get_end_line(block);
            int physical_line = first, physical_col = 0, logical_line = first, logical_col = 0;
            size_t raw_index = 0, offset = 0;
            cmark_node* active = nullptr;
            std::string literal;
            while (physical_line <= last && physical_line <= static_cast<int>(lines.size())) {
                const auto& source = lines[physical_line-1];
                if (!active && raw_index < raws.size()
                    && logical_line == cmark_node_get_start_line(raws[raw_index])
                    && logical_col == cmark_node_get_start_column(raws[raw_index])-1) {
                    active = raws[raw_index++]; offset = 0; literal = cmark_node_get_literal(active);
                }
                Position position{physical_line, physical_col};
                projection[{logical_line, logical_col}] = position;
                const bool newline = physical_col >= static_cast<int>(source.size())
                    || (source[physical_col] == '\r' && physical_col+1 == static_cast<int>(source.size()));
                const char byte = newline ? '\n' : source[physical_col];
                if (active) {
                    if (offset >= literal.size() || literal[offset] != byte)
                        throw std::runtime_error("Cannot project raw HTML bytes at line " + std::to_string(physical_line));
                    html_raw_positions[active].push_back(position);
                    ++offset; ++logical_col;
                    if (newline) {
                        ++physical_line; physical_col = 0;
                        if (offset < literal.size() && physical_line <= static_cast<int>(lines.size())) {
                            const auto stop = literal.find('\n', offset);
                            const auto segment = literal.substr(offset, stop == std::string::npos ? std::string::npos : stop-offset);
                            const auto& next = lines[physical_line-1];
                            size_t size = next.size();
                            if (size && next[size-1] == '\r') --size;
                            // All complete literal lines are exact suffixes: cmark
                            // removes only their container prefix. For the last
                            // partial line, test prefix-only gaps from left to right.
                            if (stop != std::string::npos && segment.size() <= size
                                && next.compare(size-segment.size(), segment.size(), segment) == 0)
                                physical_col = static_cast<int>(size-segment.size());
                            else {
                                while (physical_col <= static_cast<int>(size)
                                       && next.compare(physical_col, segment.size(), segment) != 0) {
                                    if (physical_col == static_cast<int>(size)
                                        || !(next[physical_col] == ' ' || next[physical_col] == '\t' || next[physical_col] == '>'))
                                        throw std::runtime_error("Cannot project HTML container prefix at line " + std::to_string(physical_line));
                                    ++physical_col;
                                }
                            }
                        }
                    } else ++physical_col;
                    if (offset == literal.size()) active = nullptr;
                } else if (newline) {
                    ++physical_line; physical_col = 0; ++logical_line; logical_col = 0;
                } else { ++physical_col; ++logical_col; }
            }
            for (auto node : nodes) {
                const auto begin = projection.find({cmark_node_get_start_line(node), cmark_node_get_start_column(node)-1});
                const auto end = projection.find({cmark_node_get_end_line(node), cmark_node_get_end_column(node)-1});
                if (begin != projection.end() && end != projection.end())
                    html_bounds[node] = {begin->second, end->second};
            }
        }
    };
    blocks(blocks, root);
}
Label label(cmark_node* node, const std::string& text, bool code = false) {
    const auto bounds = html_bounds.find(node);
    if (bounds == html_bounds.end()) return original_label(node, text, code);
    std::string raw;
    std::vector<Position> positions;
    const auto first = bounds->second.first, last = bounds->second.second;
    for (int line = first.line; line <= last.line && line <= static_cast<int>(lines.size()); ++line) {
        const auto& source = lines[line-1];
        const int begin = line == first.line ? first.column : 0;
        const int end = line == last.line ? std::min(static_cast<int>(source.size()), last.column+1) : static_cast<int>(source.size());
        for (int column = begin; column < end; ++column) { raw += source[column]; positions.push_back({line, column}); }
        if (line < last.line) { raw += '\n'; positions.push_back({line, static_cast<int>(source.size())}); }
    }
    std::string decoded;
    std::vector<Position> mapping;
    for (size_t i = 0; i < raw.size();) {
        size_t count = 1;
        std::string value(1, raw[i]);
        if (!code && raw[i] == '\\' && i+1 < raw.size() && std::ispunct(static_cast<unsigned char>(raw[i+1]))) {
            value = raw.substr(i+1, 1); count = 2;
        } else if (!code && raw[i] == '&') {
            const auto stop = raw.find(';', i+1);
            if (stop != std::string::npos && stop-i < 40) {
                const auto candidate = raw.substr(i, stop-i+1);
                const auto converted = entity(candidate);
                if (!converted.empty() && converted != candidate) { value = converted; count = candidate.size(); }
            }
        } else if (code && raw[i] == '\n') value = " ";
        decoded += value;
        mapping.insert(mapping.end(), value.size(), positions[i]);
        i += count;
    }
    Label result{text, {}};
    size_t cursor = 0;
    for (char byte : text) {
        const auto found = decoded.find(byte, cursor);
        if (found == std::string::npos) throw std::runtime_error("Cannot attribute projected source text at line " + std::to_string(first.line));
        result.positions.push_back(mapping[found]); cursor = found+1;
    }
    return result;
}
std::vector<Position> html_positions(cmark_node* node, const std::string& literal) const {
    const auto projected = html_raw_positions.find(node);
    if (projected != html_raw_positions.end()) return projected->second;
    std::vector<Position> result;
    result.reserve(literal.size());
    int line = cmark_node_get_start_line(node);
    for (size_t begin = 0; begin < literal.size();) {
        const auto newline = literal.find('\n', begin);
        const size_t end = newline == std::string::npos ? literal.size() : newline;
        const auto segment = literal.substr(begin, end-begin);
        if (line < 1 || line > static_cast<int>(lines.size()))
            throw std::runtime_error("Cannot attribute raw HTML line extent");
        const auto& source = lines[line-1];
        size_t size = source.size();
        if (size && source[size-1] == '\r') --size;
        // HTML block literals contain full source-line suffixes, with list/quote
        // container prefixes stripped by cmark. Their end fixes the unique byte
        // offset even when the same text occurs earlier on the line.
        if (segment.size() > size || source.compare(size-segment.size(), segment.size(), segment) != 0)
            throw std::runtime_error("Cannot attribute raw HTML bytes at line " + std::to_string(line));
        const size_t column = size-segment.size();
        for (size_t i = 0; i < segment.size(); ++i) result.push_back({line, static_cast<int>(column+i)});
        if (newline != std::string::npos) result.push_back({line, static_cast<int>(size)});
        begin = newline == std::string::npos ? literal.size() : newline+1;
        ++line;
    }
    return result;
}
std::string html_text(const HtmlRaw& raw, size_t begin, size_t end, bool decode, bool marked, int owner = -1) {
    Label value;
    std::string out;
    auto flush = [&] {
        if (value.text.empty()) return;
        if (marked && owner >= 0) {
            labels[owner].text += value.text;
            labels[owner].positions.insert(labels[owner].positions.end(), value.positions.begin(), value.positions.end());
            out += escape(value.text);
        } else out += marked ? span(std::move(value)) : escape(value.text);
        value = Label{};
    };
    for (size_t i = begin; i < end;) {
        size_t count = 1;
        std::string text(1, raw.literal[i]);
        if (decode && raw.literal[i] == '&') {
            const auto stop = raw.literal.find(';', i+1);
            if (stop != std::string::npos && stop < end && stop-i < 40) {
                auto candidate = raw.literal.substr(i, stop-i+1);
                auto decoded = entity(candidate);
                if (!decoded.empty() && decoded != candidate) { text = std::move(decoded); count = stop-i+1; }
            }
        }
        for (char c : text) {
            if (c == '\n') {
                flush(); out += '\n';
                if (marked && owner >= 0) { labels[owner].text += '\n'; labels[owner].positions.push_back(raw.positions[i]); }
            }
            else { value.text += c; value.positions.push_back(raw.positions[i]); }
        }
        i += count;
    }
    flush(); return out;
}
std::map<cmark_node*, bool> html_bare_text;
std::map<cmark_node*, int> html_fallback_labels;
cmark_node* html_inline_block(cmark_node* node) const {
    for (auto parent = cmark_node_parent(node); parent; parent = cmark_node_parent(parent)) {
        const auto type = cmark_node_get_type(parent);
        if (type == CMARK_NODE_PARAGRAPH || type == CMARK_NODE_HEADING
            || std::string(cmark_node_get_type_string(parent)) == "table_cell") return parent;
    }
    return nullptr;
}
int html_fallback_owner(cmark_node* node) const {
    const auto found = html_fallback_labels.find(html_inline_block(node));
    return found == html_fallback_labels.end() ? -1 : found->second;
}
std::string html_annotate(std::string html) const {
    for (const auto& entry : html_fallback_labels) {
        const std::string marker = "<!--mdview-html-fallback-" + std::to_string(entry.second) + "-->";
        const auto position = html.find(marker);
        if (position == std::string::npos || html.find(marker, position+marker.size()) != std::string::npos)
            throw std::runtime_error("Cannot locate experimental paragraph marker");
        size_t tag = position;
        for (;;) {
            if (!tag) throw std::runtime_error("Cannot locate experimental paragraph element");
            tag = html.rfind('<', tag-1);
            if (tag == std::string::npos) throw std::runtime_error("Cannot locate experimental paragraph element");
            const auto end = html.find_first_of(" >\n", tag+1);
            const auto name = html.substr(tag+1, end-tag-1);
            if (name == "p" || name == "li" || name == "td" || name == "th"
                || (name.size() == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '6')) break;
        }
        html.erase(position, marker.size());
        const auto end = html.find('>', tag);
        html.insert(end, " data-mdview=\"" + std::to_string(entry.second) + "\"");
    }
    return html;
}
void sanitize_html(cmark_node* root, bool marked) {
    html_prepare_positions(root);
    html_bare_text.clear();
    html_fallback_labels.clear(); html_root_label = -1;
    std::vector<HtmlRaw> raws;
    // Events preserve Markdown leaves between raw nodes. Labels belong to the
    // original semantic HTML elements, never geometry-changing nested spans.
    struct HtmlEvent { cmark_node* text; size_t raw; };
    std::vector<HtmlEvent> events;
    auto visit = [&](auto&& self, cmark_node* parent) -> void {
        for (auto node = cmark_node_first_child(parent); node; node = cmark_node_next(node)) {
            const auto type = cmark_node_get_type(node);
            if (type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_HTML_BLOCK) {
                HtmlRaw raw{node, cmark_node_get_literal(node), {}, {}, type == CMARK_NODE_HTML_BLOCK};
                raw.positions = html_positions(node, raw.literal);
                for (size_t i = 0; i < raw.literal.size();) {
                    HtmlToken token; token.begin = i;
                    if (raw.literal.compare(i, 4, "<!--") == 0) {
                        token.kind = HtmlToken::comment;
                        const auto close = raw.literal.find("-->", i+4);
                        token.end = close == std::string::npos ? raw.literal.size() : close+3;
                        token.valid = close != std::string::npos;
                    } else if (raw.literal[i] == '<') token = html_tag(raw.literal, i);
                    else {
                        token.kind = HtmlToken::text;
                        const auto next = raw.literal.find('<', i);
                        token.end = next == std::string::npos ? raw.literal.size() : next;
                    }
                    i = token.end; raw.tokens.push_back(std::move(token));
                }
                events.push_back({nullptr, raws.size()});
                raws.push_back(std::move(raw));
            } else if (type == CMARK_NODE_TEXT) events.push_back({node, 0});
            else self(self, node);
        }
    };
    visit(visit, root);
    // cmark safely escapes malformed tag-shaped text instead of making a raw node.
    // Still diagnose it, without reinterpreting escapes, entities, code, or fences.
    auto diagnose_text = [&](auto&& self, cmark_node* parent) -> void {
        for (auto node = cmark_node_first_child(parent); node; node = cmark_node_next(node)) {
            if (cmark_node_get_type(node) == CMARK_NODE_TEXT) {
                const std::string text = cmark_node_get_literal(node);
                if (text.find('<') == std::string::npos) continue;
                auto value = label(node, text);
                for (size_t i = 0; i+1 < text.size(); ++i) {
                    if (text[i] != '<' || !(html_letter(text[i+1]) || text[i+1] == '/' || text[i+1] == '!')) continue;
                    const auto position = value.positions[i];
                    if (position.line < 1 || position.line > static_cast<int>(lines.size())) continue;
                    const auto& source = lines[position.line-1];
                    if (position.column >= static_cast<int>(source.size()) || source[position.column] != '<') continue;
                    size_t slashes = 0;
                    for (int c = position.column-1; c >= 0 && source[c] == '\\'; --c) ++slashes;
                    if (slashes % 2) continue;
                    auto token = html_tag(text, i);
                    if (!token.valid) std::cerr << "HTML subset at " << position.line << ':' << position.column+1 << ": malformed HTML\n";
                    i = token.end ? token.end-1 : i;
                }
            } else if (cmark_node_get_type(node) != CMARK_NODE_CODE && cmark_node_get_type(node) != CMARK_NODE_CODE_BLOCK) self(self, node);
        }
    };
    diagnose_text(diagnose_text, root);
    std::vector<HtmlGroup> groups;
    struct Open { std::string name; int group; };
    std::vector<Open> stack;
    auto fail = [&](int group, const char* reason) {
        groups[group].valid = false;
        if (groups[group].reason.empty()) groups[group].reason = reason;
    };
    for (auto& raw : raws) for (auto& token : raw.tokens) {
        int group = stack.empty() ? -1 : stack.front().group;
        if (group < 0 && token.kind != HtmlToken::text) {
            group = static_cast<int>(groups.size()); groups.push_back({true, raw.positions[token.begin], {}});
        }
        token.group = group;
        if (token.kind == HtmlToken::text) continue;
        if (token.kind == HtmlToken::tag && token.name == "img") {
            if (!token.valid || token.closing || !token.has_src) token.image_error = "malformed img or missing src";
            continue;
        }
        if (!token.valid) { fail(group, token.kind == HtmlToken::comment ? "unclosed comment" : "unsupported or malformed HTML"); continue; }
        if (token.kind == HtmlToken::comment) continue;
        if (token.closing) {
            if (token.name == "br" || stack.empty() || stack.back().name != token.name) {
                fail(group, "invalid HTML nesting");
                groups[group].start = raw.positions[token.begin];
                groups[group].reason = "invalid HTML nesting";
                // A crossing close terminates its open frame, but invalidates its whole outer fragment.
                auto found = std::find_if(stack.rbegin(), stack.rend(), [&](const Open& open) { return open.name == token.name; });
                if (found != stack.rend()) stack.resize(static_cast<size_t>(stack.rend()-found-1));
            } else stack.pop_back();
        } else if (token.name != "br") {
            if (token.name == "p" || token.name == "div") {
                for (const auto& open : stack) if (open.name != "div") fail(group, "invalid block nesting");
            }
            stack.push_back({token.name, group});
        }
    }
    for (const auto& open : stack) fail(open.group, "unclosed HTML tag");
    // A raw block is opaque to cmark: on error retain its entire original literal.
    // Propagate to shared groups so no half-open sanitized wrapper survives in another node.
    bool changed;
    do {
        changed = false;
        for (auto& raw : raws) {
            if (!raw.block) continue;
            bool invalid = false;
            for (const auto& token : raw.tokens) if (token.group >= 0 && !groups[token.group].valid) invalid = true;
            if (!invalid) continue;
            for (const auto& token : raw.tokens) if (token.group >= 0 && groups[token.group].valid) {
                fail(token.group, "invalid opaque HTML fragment"); changed = true;
            }
        }
    } while (changed);
    for (const auto& group : groups) if (!group.valid)
        std::cerr << "HTML subset at " << group.start.line << ':' << group.start.column+1 << ": " << group.reason << '\n';
    // Only surviving img tokens may reach the local decoder. Invalid wrappers stay opaque.
    for (auto& raw : raws) for (auto& token : raw.tokens) {
        if (token.name != "img" || (token.group >= 0 && !groups[token.group].valid)) continue;
        if (token.image_error.empty()) {
            std::string reason;
            if (!html_images::preflight(token.src, reason)) token.image_error = reason;
        }
        if (!token.image_error.empty()) {
            const auto position = raw.positions[token.begin];
            std::cerr << "HTML subset at " << position.line << ':' << position.column+1 << ": " << token.image_error << '\n';
        }
    }
    if (marked) for (const auto& raw : raws) {
        bool invalid = false;
        for (const auto& token : raw.tokens)
            if ((token.group >= 0 && !groups[token.group].valid) || !token.image_error.empty()) invalid = true;
        if (!invalid) continue;
        if (raw.block) {
            if (html_root_label < 0) { html_root_label = static_cast<int>(labels.size()); labels.push_back(Label{}); }
        } else if (auto block = html_inline_block(raw.node)) {
            if (html_fallback_labels.count(block)) continue;
            const int id = static_cast<int>(labels.size());
            labels.push_back(Label{}); html_fallback_labels[block] = id;
            auto marker = cmark_node_new(CMARK_NODE_CUSTOM_INLINE);
            const auto literal = "<!--mdview-html-fallback-" + std::to_string(id) + "-->";
            cmark_node_set_on_enter(marker, literal.c_str());
            cmark_node_set_on_exit(marker, "");
            if (!cmark_node_prepend_child(block, marker)) { cmark_node_free(marker); throw std::runtime_error("Cannot mark fallback paragraph"); }
        }
    }
    struct NativeOwner { int id; bool inline_text; };
    std::vector<NativeOwner> owners;
    auto owner = [&] { return owners.empty() ? -1 : owners.back().id; };
    for (const auto& event : events) {
        if (event.text) {
            // Retain normal Markdown labels inside block wrappers: HTML's
            // implicit paragraph closure can move those nodes outside a raw p.
            const int fallback = html_fallback_owner(event.text);
            const int text_owner = owner() >= 0 && owners.back().inline_text ? owner() : fallback;
            if (marked && text_owner >= 0) {
                const auto value = label(event.text, cmark_node_get_literal(event.text));
                labels[text_owner].text += value.text;
                labels[text_owner].positions.insert(labels[text_owner].positions.end(), value.positions.begin(), value.positions.end());
                html_bare_text[event.text] = true;
            }
            continue;
        }
        const auto& raw = raws[event.raw];
        const int raw_owner = owner() >= 0 ? owner() : html_fallback_owner(raw.node);
        bool invalid_block = false;
        if (raw.block) for (const auto& token : raw.tokens)
            if (token.group >= 0 && !groups[token.group].valid) invalid_block = true;
        // Standalone images use the same paragraph geometry as Markdown images.
        // Explicit HTML containers keep their own semantics.
        bool image_paragraph = raw.block && !invalid_block;
        bool has_image = false;
        for (const auto& token : raw.tokens) {
            if (token.kind == HtmlToken::tag && token.name == "img" && token.valid
                && token.image_error.empty()) has_image = true;
            else if (token.kind != HtmlToken::text
                     || raw.literal.substr(token.begin, token.end-token.begin).find_first_not_of(" \t\r\n") != std::string::npos)
                image_paragraph = false;
        }
        image_paragraph = image_paragraph && has_image;
        std::string html;
        if (invalid_block) html = html_text(raw, 0, raw.literal.size(), false, marked, html_root_label);
        else for (const auto& token : raw.tokens) {
            if (token.group >= 0 && !groups[token.group].valid) {
                html += html_text(raw, token.begin, token.end, false, marked, raw_owner); continue;
            }
            if (token.kind == HtmlToken::comment) {
                html_comments.push_back({raw.positions[token.begin], raw.positions[token.end-1]});
                continue;
            }
            if (token.kind == HtmlToken::text) {
                html += html_text(raw, token.begin, token.end, true, marked, owner() >= 0 ? owner() : html_fallback_owner(raw.node));
                continue;
            }
            if (token.name == "img") {
                if (!token.image_error.empty()) {
                    html += html_text(raw, token.begin, token.end, false, marked, raw.block ? html_root_label : raw_owner);
                    continue;
                }
                html += "<img src=\"" + escape(token.src) + "\" alt=\"" + escape(token.alt) + "\"";
                if (marked) {
                    const auto first = raw.positions[token.begin], last = raw.positions[token.end-1];
                    html += " data-mdview-image=\"" + std::to_string(first.line)
                        + "\" data-mdview-image-column=\"" + std::to_string(first.column)
                        + "\" data-mdview-image-end-line=\"" + std::to_string(last.line)
                        + "\" data-mdview-image-end=\"" + std::to_string(last.column) + "\"";
                }
                html += ">";
                continue;
            }
            if (token.name == "span") continue;
            if (token.name == "br") {
                html += "<br";
                if (marked) {
                    const auto position = raw.positions[token.begin];
                    html += " data-mdview-break=\"" + std::to_string(position.line) + "\" data-mdview-break-column=\"" + std::to_string(position.column) + "\"";
                }
                html += ">";
            } else if (token.closing) {
                html += "</" + token.name + ">";
                if (marked) owners.pop_back();
            } else {
                html += "<" + token.name;
                if (marked) {
                    const int id = static_cast<int>(labels.size());
                    labels.push_back(Label{});
                    owners.push_back({id, token.name == "kbd" || token.name == "sup" || token.name == "sub"});
                    html += " data-mdview=\"" + std::to_string(id) + "\"";
                }
                html += ">";
            }
        }
        if (image_paragraph) html = "<p>" + html + "</p>";
        auto replacement = cmark_node_new(raw.block ? CMARK_NODE_CUSTOM_BLOCK : CMARK_NODE_CUSTOM_INLINE);
        cmark_node_set_on_enter(replacement, html.c_str());
        cmark_node_set_on_exit(replacement, "");
        if (!cmark_node_replace(raw.node, replacement)) { cmark_node_free(replacement); throw std::runtime_error("Cannot install sanitized HTML"); }
        cmark_node_free(raw.node);
    }
}
