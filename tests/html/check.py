#!/usr/bin/env python3
"""Run: python3 tests/html/check.py (after scripts/build-html-subset).

Native-only, dependency-free behavioral checks. Plugin lifecycle checks are separate:
  nvim --headless -u NONE -l tests/html/regression.lua
The coordinate oracle reads actual Container.draw_text calls, never DRAW's selected
source anchor or the implementation's FRAG trace. No production renderer is replaced.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
import os
import re
import selectors
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "build/html-subset/mdview-preview"
CSS = ROOT / "styles/markdown.css"
WIDTHS = (240, 420, 760)
HEIGHT = 4096


class Body(HTMLParser):
    def __init__(self, document):
        super().__init__(convert_charrefs=True)
        self.inside = False
        self.tags = []
        self.attrs = []
        self.parts = []
        self.feed(document)

    def handle_starttag(self, tag, attrs):
        if tag == "main":
            self.inside = True
            return
        if self.inside:
            self.tags.append(tag)
            self.attrs.extend((tag, key, value) for key, value in attrs)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag == "main":
            self.inside = False

    def handle_data(self, text):
        if self.inside:
            self.parts.append(text)

    @property
    def text(self):
        return "".join(self.parts)


@dataclass
class Token:
    raw: str
    visible: str | None = None
    occurrence: int = 0


@dataclass
class Case:
    name: str
    source: str
    visible: tuple[str, ...] = ()
    hidden: tuple[str, ...] = ()
    tags: tuple[str, ...] = ()
    absent: tuple[str, ...] = ()
    tokens: tuple[Token, ...] = ()
    error_at: str | None = None
    body: str | None = None
    navigation: tuple[tuple[str, str], ...] = ()
    breaks: tuple[tuple[str, str], ...] = ()
    br_anchor: bool = False


def document(body):
    return "# PRE001\n\n" + body + "\n\n# POST001\n"


def cases():
    result = [
        Case("br-variants", document("a001<br>b001<br/>c001<br />d001"),
             visible=("a001", "b001", "c001", "d001"), tags=("br",),
             tokens=tuple(Token(x) for x in ("a001", "b001", "c001", "d001")),
             breaks=(("a001", "b001"), ("b001", "c001"), ("c001", "d001"))),
        Case("br-block-only", document("<br>\n\nafterbreak001"), tags=("br",),
             tokens=(Token("afterbreak001"),), br_anchor=True),
        Case("nested-repeated", document("before001 <kbd>repeat001 <sup>upper001 <sub>lower001 <span>repeat001</span></sub></sup></kbd> after001"),
             tags=("kbd", "sup", "sub"), tokens=(Token("before001"), Token("repeat001"),
             Token("upper001"), Token("lower001"), Token("repeat001", occurrence=1), Token("after001"))),
        Case("nested-br-variants", document("before024 <kbd>kbd024<br><sup>sup024<br/><sub>sub024<br /><span>span024</span></sub></sup></kbd> after024"),
             tags=("kbd", "sup", "sub", "br"),
             tokens=tuple(Token(x) for x in ("before024", "kbd024", "sup024", "sub024", "span024", "after024")),
             breaks=(("kbd024", "sup024"), ("sup024", "sub024"), ("sub024", "span024"))),
        Case("repeated-unicode", document("<span>café 東京</span> <kbd>café 東京</kbd>"),
             tokens=(Token("café"), Token("東京"), Token("café", occurrence=1), Token("東京", occurrence=1))),
        Case("unicode-entities", document("before002 <span>café 東京 &amp; &#233; &#x1F642; &lt;tag&gt;</span> after002"),
             visible=("café 東京 & é 🙂 <tag>",), absent=("tag",),
             tokens=(Token("before002"), Token("café"), Token("東京"), Token("&amp;", "&"),
                     Token("&#233;", "é"), Token("&#x1F642;", "🙂"), Token("after002"))),
        Case("multiline", document("before003 <kbd>key003\n<span>inner003\n<sup>upper003</sup></span></kbd> after003"),
             tokens=tuple(Token(x) for x in ("before003", "key003", "inner003", "upper003", "after003"))),
        Case("inline-comment", document("before004<!-- hidden004\ncontinued hidden004 -->after004"),
             visible=("before004", "after004"), hidden=("hidden004",),
             tokens=(Token("before004"), Token("after004"))),
        Case("spaced-inline-comment", document("Before <!-- complete\nmultiline comment --> after comment."),
             visible=("Before", "after comment."), hidden=("complete", "multiline"),
             tokens=(Token("Before"), Token("after"), Token("comment."))),
        Case("comment-literal-extent", document("<!-- hidden005\nsecond hidden005\n-->tail005"),
             hidden=("hidden005",), tokens=(Token("tail005"),), navigation=(("-->", "tail005"),)),
        Case("comment-next", "# PRE001\n\n<!-- hidden006\ncomment006 -->\n\nnext006\n",
             hidden=("hidden006", "comment006"), tokens=(Token("next006"),),
             navigation=(("<!--", "next006"),)),
        Case("comment-previous", "# PRE001\n\nprevious007\n\n<!-- hidden007\ncomment007 -->\n",
             hidden=("hidden007", "comment007"), tokens=(Token("previous007"),),
             navigation=(("<!--", "previous007"),)),
        Case("opaque-p", document("<p>opaque008 **raw008** <kbd>key008</kbd> &amp; café</p>\n\n**parsed008**"),
             visible=("**raw008**", "& café", "parsed008"), tags=("p", "kbd", "strong"),
             tokens=(Token("opaque008"), Token("key008"), Token("parsed008")),
             body="<h1>PRE001</h1>\n<p>opaque008 **raw008** <kbd>key008</kbd> &amp; café</p>\n<p><strong>parsed008</strong></p>\n<h1>POST001</h1>\n"),
        Case("opaque-div", document("<div>\nopaque009 **raw009** <span>inner009</span>\n</div>\n\n**parsed009**"),
             visible=("**raw009**", "parsed009"), tags=("div", "strong"),
             tokens=(Token("opaque009"), Token("inner009"), Token("parsed009"))),
        Case("blockquote-opaque", document("> <div>\n> quoted025 **raw025** <kbd>key025</kbd>\n> </div>\n>\n> after025"),
             visible=("**raw025**",), tags=("blockquote", "div", "kbd"),
             tokens=tuple(Token(x) for x in ("quoted025", "key025", "after025"))),
        Case("list-opaque", document("- <div>\n  listed026 **raw026** <span>inner026</span>\n  </div>\n\n  after026"),
             visible=("**raw026**",), tags=("ul", "li", "div"),
             tokens=tuple(Token(x) for x in ("listed026", "inner026", "after026"))),
        Case("quote-list-opaque", document("> - <div>\n>   nested027 **raw027** <kbd>key027</kbd>\n>   </div>\n>\n>   after027"),
             visible=("**raw027**",), tags=("blockquote", "ul", "li", "div", "kbd"),
             tokens=tuple(Token(x) for x in ("nested027", "key027", "after027"))),
        Case("blank-separated-div", document("<div>\n\n**parsed010**\n\n</div>"),
             tags=("div", "strong"), hidden=("**parsed010**",), tokens=(Token("parsed010"),)),
        Case("blank-separated-p", document("<p>\n\n**parsed011**\n\n</p>"),
             tags=("p", "strong"), hidden=("**parsed011**",), tokens=(Token("parsed011"),)),
        Case("escaped-inline-code-fence", document("\\<kbd>escaped012\\</kbd>\n\n`<span>code012</span>`\n\n```html\n<div>fence012</div>\n<!-- fencecomment012 -->\n```"),
             visible=("<kbd>escaped012</kbd>", "<span>code012</span>", "<div>fence012</div>", "<!-- fencecomment012 -->"),
             tags=("code", "pre"), absent=("kbd", "div"),
             tokens=(Token("escaped012", "<kbd>escaped012</kbd>"), Token("code012", "<span>code012</span>"),
                     Token("fence012", "<div>fence012</div>"))),
    ]
    hostile = (' style="display:none;color:red" onclick="evil()" onerror="evil()"'
               ' id="evil-id" class="evil-class" align="right" width="1" height="1"'
               ' href="https://invalid.example/never" src="file:///never-resource"'
               ' data-mdview="999999" data-mdview-image="999999"'
               ' data-mdview-mermaid="999999" data-mdview-mermaid-end="999999"'
               ' data-mdview-break="999999" data-mdview-break-column="999999"'
               ' title="quoted > delimiter"')
    for tag in ("kbd", "sup", "sub", "span", "p", "div"):
        token = "safe" + tag + "013"
        result.append(Case("attributes-" + tag, document("<" + tag + hostile + ">" + token + "</" + tag + ">\n\nafter013"),
                           tokens=(Token(token), Token("after013")),
                           hidden=("evil()", "evil-id", "quoted > delimiter", "never-resource", "999999")))
    result.append(Case("attributes-br", document("before014<br" + hostile + "/>after014"),
                       tags=("br",), tokens=(Token("before014"), Token("after014")),
                       hidden=("evil()", "999999"), breaks=(("before014", "after014"),)))
    for tag in ("details", "summary", "picture", "source", "img", "table", "a", "section", "iframe", "script", "style"):
        literal = "<" + tag + ">unsupported015</" + tag + ">"
        if tag == "script":
            literal = "<script>script015 alert('never')</script>"
        if tag == "style":
            literal = "<style>.markdown-body { display:none }</style>"
        result.append(Case("unsupported-" + tag, document(literal + "\nfollowing015"),
                           visible=(literal, "following015", "POST001"), absent=(tag,),
                           tokens=(Token("following015"),), error_at="<" + tag + ">"))
    result.extend((
        Case("unsupported-picture-adjacent", document("prefix<picture>inner</picture>suffix"),
             visible=("prefix<picture>inner</picture>suffix",), absent=("picture",),
             tokens=(Token("prefix<picture>inner</picture>suffix"),), error_at="<picture>"),
        Case("unsupported-picture-unicode-adjacent", document("répété<picture>inner</picture>répété"),
             visible=("répété<picture>inner</picture>répété",), absent=("picture",),
             tokens=(Token("répété<picture>inner</picture>répété"),), error_at="<picture>"),
        Case("invalid-img-allowed-enclosure", document("répété before<kbd><img>inner</kbd>after répété"),
             visible=("before", "<img>inner", "after"), tags=("kbd",), absent=("img",),
             tokens=(Token("répété"), Token("before"), Token("<img>inner"), Token("after"), Token("répété", occurrence=1)),
             error_at="<img>"),
    ))
    for name, bad, position in (
        ("mismatched", "before016 <span>open016</kbd> following016", "</kbd>"),
        ("unclosed-wrapper", "<div>open017\nrest017\n# swallowed017", "<div>"),
        ("unclosed-comment", "<!-- open018\nrest018\n# swallowed018", "<!--"),
        ("stray-close", "before019 </span> after019", "</span>"),
        ("bad-attribute", "<span title=\"unfinished>bad020\nrest020", "<span"),
        ("bad-nesting", "<p><div>bad021</p></div>\nrest021", "</p>"),
    ):
        # Affected fragments must become literal, never drop cmark-absorbed source.
        result.append(Case(name, document(bad), visible=(bad.split("\n")[-1], "POST001"),
                           error_at=position))
    return result


def run(args, *, env=None, input=None):
    completed = subprocess.run([str(x) for x in args], input=input, text=True,
                               capture_output=True, timeout=30, env=env)
    assert completed.returncode == 0, f"{args}: {completed.stderr}\n{completed.stdout}"
    return completed


def position(source, raw, occurrence=0):
    data, needle = source.encode(), raw.encode()
    offset = -1
    for _ in range(occurrence + 1):
        offset = data.index(needle, offset + 1)
    line = data[:offset].count(b"\n") + 1
    column = offset - (data.rfind(b"\n", 0, offset) + 1)
    return line, column, column + len(needle) - 1


def traces(path):
    result = []
    for row in path.read_text().splitlines():
        parts = row.split("\t")
        if parts[0] == "TEXT":
            assert len(parts) == 6, f"invalid independent draw trace: {row}"
            text = "" if parts[1] == "-" else bytes.fromhex(parts[1]).decode()
            result.append((text, *(float(x) for x in parts[2:])))
    assert result, "Container.draw_text trace missing: coordinate oracle cannot be replaced by FRAG"
    return result


class Worker:
    def __init__(self, directory, trace):
        self.stderr_path = directory / "worker.stderr"
        self.stderr = self.stderr_path.open("wb")
        env = os.environ.copy()
        env["MDVIEW_HTML_TRACE"] = str(trace)
        self.process = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, text=True, bufsize=1, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.revision = 0
        self.sequence = 0

    def request(self, request, terminal):
        self.process.stdin.write(request + "\n")
        self.process.stdin.flush()
        rows = []
        deadline = time.monotonic() + 30
        # Read bytes directly to avoid TextIO read-ahead defeating select on pipes.
        pending = b""
        while time.monotonic() < deadline:
            assert self.selector.select(max(0, deadline - time.monotonic())), f"timeout: {request}"
            block = os.read(self.process.stdout.fileno(), 65536)
            assert block, f"worker exited: {self.stderr_path.read_text()}"
            pending += block
            while b"\n" in pending:
                row, pending = pending.split(b"\n", 1)
                text = row.decode()
                assert not text.startswith("ERROR "), f"LOAD/DRAW aborted: {text}\n{self.stderr_path.read_text()}"
                rows.append(text)
                if text.startswith(terminal + " "):
                    assert not pending, "unexpected unsolicited renderer output"
                    return rows
        raise AssertionError("worker request deadline exceeded")

    def load(self, source, stylesheet, width, directory):
        self.revision += 1
        rows = self.request(f"LOAD {self.revision} {width} {hx(source)} {hx(directory)} {hx(stylesheet)}", "READY")
        fragments = [tuple(float(x) if n == 3 else int(x) for n, x in enumerate(row.split()[1:]))
                     for row in rows if row.startswith("FRAG ")]
        assert fragments, "successful LOAD has no original source anchors"
        ready = rows[-1].split()
        assert int(ready[1]) == self.revision and int(ready[2]) == width
        return fragments

    def draw(self, output, *, line=0, column=0):
        self.sequence += 1
        row = self.request(f"DRAW {self.revision} {self.sequence} {line} {column} 0 {HEIGHT} {hx(output)}", "FRAME")[-1].split()
        assert int(row[1]) == self.revision and int(row[2]) == self.sequence
        assert output.is_file(), "DRAW did not publish a raster"
        return int(row[5])

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.write("QUIT\n")
            self.process.stdin.flush()
        self.process.communicate(timeout=10)
        self.stderr.close()
        self.selector.close()
        assert self.process.returncode == 0


def hx(value):
    return str(value).encode().hex()


def coordinates(case, fragments, calls):
    expected = (Token("PRE001"),) + case.tokens
    if "POST001" in case.source:
        expected += (Token("POST001"),)
    cursors = {}
    observed = {}
    for token in expected:
        line, start, end = position(case.source, token.raw, token.occurrence)
        visible = token.visible if token.visible is not None else token.raw
        if token.raw.startswith("&"):
            end = start  # Each decoded UTF-8 byte maps to the entity's original '&'.
        candidates = [f for f in fragments if f[0] == line and f[1] <= end and f[2] >= start]
        covered = {column for f in candidates for column in range(max(start, f[1]), min(end, f[2]) + 1)}
        required = set(range(start, end + 1))
        assert required <= covered, (
            f"{case.name}: lost original UTF-8 bytes for {token}: expected {line}:{start}-{end}, got {fragments}")
        # CJK and wrapping can split one token into several legitimate draw leaves.
        # Join only contiguous actual draw calls; repeated values consume occurrences
        # in order. The implementation's FRAG trace is deliberately never consulted.
        begin = cursors.get(visible, 0)
        matched = None
        for first in range(begin, len(calls)):
            combined = ""
            leaves = []
            for index in range(first, len(calls)):
                call = calls[index]
                text = call[0].strip()
                if not text:
                    continue
                offset = len(combined.encode())
                combined += text
                if not visible.startswith(combined):
                    break
                leaves.append((index, call, offset, len(combined.encode())))
                if combined == visible:
                    matched = leaves
                    break
            if matched:
                break
        assert matched, f"{case.name}: independent draw_text did not draw {visible!r}"
        cursors[visible] = matched[-1][0] + 1
        if token.raw.startswith("&"):
            mapping = {offset: start for offset in range(len(visible.encode()))}
        else:
            # Literal/code draw leaves may include tag-shaped punctuation around the
            # fixture marker. Map the marker bytes, not that unrelated punctuation.
            prefix = visible.encode().index(token.raw.encode())
            mapping = {prefix + offset: start + offset for offset in range(len(token.raw.encode()))}
        for _, call, first, last in matched:
            columns = {mapping[offset] for offset in range(first, last) if offset in mapping}
            if not columns:
                continue
            leaves = [f for f in candidates if any(f[1] <= column <= f[2] for column in columns)]
            assert leaves, f"{case.name}: drawn leaf {call[0]!r} has no original source bytes"
            # Draw callbacks expose pixel-rounded positions, unlike layout FRAGs.
            assert all(abs(f[3] - call[2]) <= 0.5 for f in leaves), (
                f"{case.name}: source {line}:{sorted(columns)} FRAG y differs from real draw_text: {leaves} vs {call}")
        observed[token.raw] = min(call[2] for _, call, _, _ in matched)
    for before, after in case.breaks:
        assert observed[after] > observed[before], f"{case.name}: br did not advance drawing baseline"
    return observed


def diagnostic(stderr, case):
    line, column, _ = position(case.source, case.error_at)
    # Human diagnostics are 1-based, unlike FRAG's byte columns.
    locations = [(int(a), int(b)) for a, b in re.findall(r"(?:line\s+)?(\d+)\s*(?::|,?\s+column\s+)\s*(\d+)", stderr)]
    assert (line, column + 1) in locations, (
        f"{case.name}: missing localized diagnostic at {line}:{column + 1}: {stderr!r}")


def check_case(case, directory):
    prefix = directory / case.name
    source = prefix.with_suffix(".md")
    source.write_bytes(case.source.encode())
    original = source.read_bytes()
    generated = {}
    for mode in ("plain", "marked"):
        result = run((BINARY, "--html", source, CSS, mode))
        if case.error_at:
            diagnostic(result.stderr, case)
        else:
            assert not result.stderr.strip(), f"{case.name}: supported HTML reported diagnostic: {result.stderr}"
        parsed = Body(result.stdout)
        for token in ("PRE001", "POST001"):
            if token in case.source:
                assert token in parsed.text, f"{case.name}: unrelated heading swallowed"
        for text in case.visible:
            assert text in parsed.text, f"{case.name}: missing literal/content {text!r}: {parsed.text!r}"
        for text in case.hidden:
            assert text not in parsed.text, f"{case.name}: comment/attribute/code boundary leaked {text!r}"
        for tag in case.tags:
            assert tag in parsed.tags, f"{case.name}: missing sanitized {tag} semantics"
        for tag in case.absent:
            assert tag not in parsed.tags, f"{case.name}: forbidden {tag} reached native HTML"
        if case.name.startswith("attributes-"):
            for tag, key, value in parsed.attrs:
                assert mode == "marked" and value.isdecimal(), (
                    f"{case.name}: user attribute reached litehtml: {tag} {key}={value}")
                if key == "data-mdview":
                    assert value != "999999", "supplied metadata impersonated a trusted text label"
                elif case.name == "attributes-br" and tag == "br" and key in ("data-mdview-break", "data-mdview-break-column"):
                    line, column, _ = position(case.source, "<br")
                    expected = line if key == "data-mdview-break" else column
                    assert int(value) == expected, "br marker does not describe original source bytes"
                else:
                    raise AssertionError(f"{case.name}: supplied attribute reached litehtml: {tag} {key}={value}")
        output = prefix.with_suffix("." + mode + ".html")
        output.write_text(result.stdout)
        generated[mode] = output
    for width in WIDTHS:
        pixels = {}
        for mode in ("plain", "marked"):
            raster = directory / f"{case.name}-{mode}-{width}.rgba"
            trace = raster.with_suffix(".trace")
            env = os.environ.copy()
            env["MDVIEW_HTML_TRACE"] = str(trace)
            run((BINARY, "--render-html", generated[mode], width, HEIGHT, raster), env=env)
            assert raster.stat().st_size == width * HEIGHT * 4, "invalid native raster extent"
            pixels[mode] = raster.read_bytes()
        assert pixels["plain"] == pixels["marked"], f"{case.name}/{width}: instrumentation changes sanitized native pixels"
        if case.body:
            trusted = directory / f"{case.name}-trusted.html"
            trusted.write_text('<!doctype html><html><head><meta charset="utf-8"><style>' + CSS.read_text()
                               + '</style></head><body><main class="markdown-body">' + case.body + '</main></body></html>')
            oracle = directory / f"{case.name}-trusted-{width}.rgba"
            run((BINARY, "--render-html", trusted, width, HEIGHT, oracle))
            assert oracle.read_bytes() == pixels["plain"], f"{case.name}/{width}: opaque block differs from hand-authored sanitized HTML"
        trace = directory / f"{case.name}-worker-{width}.trace"
        worker = Worker(directory, trace)
        try:
            fragments = worker.load(source, CSS, width, directory)
            raster = directory / f"{case.name}-worker-{width}.rgba"
            assert worker.draw(raster) == 0
            assert raster.read_bytes() == pixels["marked"], f"{case.name}/{width}: LOAD differs from --html native oracle"
            calls = traces(trace)
            coordinates(case, fragments, calls)
            if case.br_anchor:
                line, column, _ = position(case.source, "<br>")
                anchors = [f for f in fragments if f[0] == line and f[1] == column]
                assert anchors, "br-only line has no source anchor"
                top = worker.draw(raster, line=line, column=column)
                assert top == int(anchors[0][3]), "br-only navigation ignored its own source line"
            for comment, target in case.navigation:
                line, column, _ = position(case.source, comment)
                assert not any(f[0] == line and f[1] <= column <= f[2] for f in fragments), "complete comment fabricated visible source leaf"
                top = worker.draw(raster, line=line, column=column)
                target_line, target_column, _ = position(case.source, target)
                anchor = next(f for f in fragments if f[0] == target_line and f[1] <= target_column <= f[2])
                assert top == int(anchor[3]), "comment navigation did not choose next/previous visible anchor"
        finally:
            worker.close()
    assert source.read_bytes() == original, f"{case.name}: renderer mutated original source bytes"


def recovery(directory):
    source = directory / "recovery.md"
    trace = directory / "recovery.trace"
    worker = Worker(directory, trace)
    pid = worker.process.pid
    try:
        for n, text in enumerate(("<span>valid022</span>", "<script>bad022</script> following022", "<span>corrected022</span>")):
            source.write_text(document(text))
            original = source.read_bytes()
            worker.load(source, CSS, 420, directory)
            worker.draw(directory / f"recovery-{n}.rgba")
            assert worker.process.pid == pid and worker.process.poll() is None, "HTML diagnostics restarted worker"
            assert source.read_bytes() == original, "recovery mutated source"
        assert (directory / "recovery-0.rgba").read_bytes() != (directory / "recovery-1.rgba").read_bytes()
        assert (directory / "recovery-1.rgba").read_bytes() != (directory / "recovery-2.rgba").read_bytes(), "corrected HTML retained obsolete pixels"
    finally:
        worker.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="store_true", help="retain native raster/trace artifacts on success")
    args = parser.parse_args()
    assert BINARY.is_file() and os.access(BINARY, os.X_OK), "Run scripts/build-html-subset first; production binary is not an oracle substitute"
    directory = Path(tempfile.mkdtemp(prefix="mdview-html-check-"))
    try:
        matrix = cases()
        for case in matrix:
            check_case(case, directory)
            if not args.keep:
                for artifact in directory.glob(case.name + "-*"):
                    artifact.unlink()
        recovery(directory)
    except Exception:
        print(f"FAIL artifacts: {directory}", flush=True)
        raise
    print(f"PASS: {len(matrix)} closed-subset cases, {len(WIDTHS)} widths, independent draw_text/source-byte coordinates, native plain/marked and sanitized block pixels, persistent recovery")
    if args.keep:
        print(f"Artifacts: {directory}")
    else:
        shutil.rmtree(directory)


if __name__ == "__main__":
    main()
