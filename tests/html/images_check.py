#!/usr/bin/env python3
"""Run after scripts/build-html-subset; no downloads, renderer mocks or benchmarks."""
from __future__ import annotations

import json
import os
from pathlib import Path
import struct
import tempfile
import zlib

import check

ROOT = check.ROOT
EXPERIMENT = check.BINARY
STOCK = ROOT / "build/mdview-preview"
OBSERVED = Path(__file__).with_name("images-observed.json")


def png(path, width, height, alpha=False):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    compressor = zlib.compressobj()
    pieces = []
    colors = (b"\x35\x92\xc7\xff", b"\xc7\x35\x92\x80", b"\x92\xc7\x35\x00")
    row = b"\0" + (b"".join(colors[x % 3] for x in range(width)) if alpha else colors[0] * width)
    for _ in range(height):
        pieces.append(compressor.compress(row))
    pieces.append(compressor.flush())
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", b"".join(pieces)) + chunk(b"IEND", b""))


def dimensions(path):
    return check.run(["magick", "identify", "-format", "%w %h", path]).stdout


def equal(a, b):
    import subprocess
    result = subprocess.run(["magick", "compare", "-metric", "AE", str(a), str(b), "null:"],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode in (0, 1), result.stderr
    assert float(result.stderr.split()[0]) == 0, f"pixel mismatch: {result.stderr}"
    assert dimensions(a) == dimensions(b), "viewport dimensions differ"


def inspect(source):
    result = check.run([EXPERIMENT, "--html", source, check.CSS, "plain"])
    return check.Body(result.stdout), result.stderr, result.stdout


def main():
    assert EXPERIMENT.is_file() and STOCK.is_file(), "Build isolated and stock workers first"
    observations = []
    with tempfile.TemporaryDirectory(prefix="mdview-html-images-") as temp:
        directory = Path(temp)
        for name in ("small.png", "space name.png", "東京 café.png", "amp&name.png", "literal%20.png"):
            png(directory / name, 37, 23, alpha=True)
        (directory / "corrupt.png").write_bytes(b"not an image")
        (directory / "truncated.png").write_bytes((directory / "small.png").read_bytes()[:33])
        (directory / "resource.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"><image href="https://invalid.example/no"/></svg>')
        for name, w, h in (("wide.png", 8193, 1), ("tall.png", 1, 8193), ("pixels.png", 4097, 4097)):
            png(directory / name, w, h)
        with (directory / "encoded.png").open("wb") as handle:
            handle.write((directory / "small.png").read_bytes())
            handle.truncate(64 * 1024 * 1024 + 1)
        png(directory / "budget-a.png", 4096, 3072)
        for name in ("budget-b.png", "budget-c.png"):
            os.link(directory / "budget-a.png", directory / name)
        trace = directory / "draw.trace"
        image_trace = directory / "images.trace"
        previous_trace = os.environ.get("MDVIEW_HTML_IMAGE_TRACE")
        os.environ["MDVIEW_HTML_IMAGE_TRACE"] = str(image_trace)
        experimental = check.Worker(directory, trace)
        stock_directory = directory / "stock"
        stock_directory.mkdir()
        check.BINARY = STOCK
        stock = check.Worker(stock_directory, stock_directory / "trace")
        check.BINARY = EXPERIMENT
        source = directory / "source.md"
        stock_source = directory / "markdown.md"
        serial = 0
        def render(text, width=420):
            nonlocal serial
            serial += 1
            source.write_text(text)
            fragments = experimental.load(source, check.CSS, width, directory)
            output = directory / f"html-{serial}.png"
            experimental.draw(output)
            return output, fragments
        try:
            paths = (("small.png", "small.png"), ("space name.png", "space%20name.png"),
                     ("東京 café.png", "%E6%9D%B1%E4%BA%AC%20caf%C3%A9.png"),
                     ("amp&amp;name.png", "amp%26name.png"), ("literal%2520.png", "literal%2520.png"))
            for raw, markdown in paths:
                for inline in (False, True):
                    image = f'<img src="{raw}" alt="sample &amp; café">'
                    body = "before " + image + " after" if inline else image
                    md = "![sample & café](" + markdown + ")"
                    md = "before " + md + " after" if inline else md
                    for width in (240, 760):
                        output, fragments = render(check.document(body), width)
                        parsed, diagnostics, _ = inspect(source)
                        assert diagnostics == "", diagnostics
                        attrs = [(key, value) for tag, key, value in parsed.attrs if tag == "img"]
                        assert dict(attrs)["alt"] == "sample & café"
                        assert all(key in ("src", "alt") for key, _ in attrs), attrs
                        image_rows = [row.split("\t") for row in image_trace.read_text().splitlines()
                                      if row.startswith("IMAGE\t")]
                        assert image_rows and any(row[2:4] == ["37", "23"] for row in image_rows), "natural image dimensions missing"
                        line, col, _ = check.position(source.read_text(), image)
                        assert any(f[0] == line and f[1] <= col <= f[2] for f in fragments), "missing original img anchor"
                        stock_source.write_text(check.document(md))
                        stock.load(stock_source, check.CSS, width, directory)
                        reference = directory / "stock.png"
                        stock.draw(reference)
                        equal(output, reference)
                        observations.append({"src": raw, "inline": inline, "width": width,
                                             "pixels": "equal-stock-Markdown", "viewport": dimensions(output)})
            for suffix in ("jpg", "gif", "bmp", "webp"):
                image_path = directory / ("format." + suffix)
                check.run(["magick", directory / "small.png", image_path])
                output, _ = render(check.document(f'<img src="{image_path.name}" alt="format">'))
                stock_source.write_text(check.document(f'![format]({image_path.name})'))
                stock.load(stock_source, check.CSS, 420, directory)
                reference = directory / "stock.png"
                stock.draw(reference)
                equal(output, reference)
                observations.append({"format": suffix, "pixels": "equal-stock-Markdown"})
            check.run(["magick", directory / "small.png", directory / "small.png", directory / "animated.gif"])
            hostile = (' width="1" height="99999" style="display:none; background:url(https://invalid.example/x)"'
                       ' srcset="https://invalid.example/x 1x" onclick="evil()" onerror="evil()"'
                       ' data-mdview="99999" data-mdview-image="99999"')
            clean, _ = render(check.document('<img src="small.png" alt="sample">'))
            dirty, _ = render(check.document('<img src="small.png" alt="sample"' + hostile + '>'))
            equal(clean, dirty)
            parsed, diagnostics, _ = inspect(source)
            assert diagnostics == ""
            assert all(key in ("src", "alt") for tag, key, _ in parsed.attrs if tag == "img")
            rejected = ["missing.png", "corrupt.png", "truncated.png", "wide.png", "tall.png", "pixels.png", "encoded.png", "resource.svg", "animated.gif",
                        "http://invalid.example/x", "https://invalid.example/x", "data:image/png;base64,AAAA",
                        "file:///tmp/no.png", "//invalid.example/x", "ftp://invalid.example/x", "javascript:evil()",
                        "%68%74%74%70%3A%2F%2Finvalid.example/x", "bad%00.png", "bad%ZZ.png"]
            for url in rejected:
                literal = f'<img src="{url}" alt="bad &amp; image">'
                before_image_trace = image_trace.read_bytes()
                output, _ = render(check.document("before " + literal + " after"))
                parsed, diagnostics, raw = inspect(source)
                assert "img" not in parsed.tags, f"rejected image reached layout: {url}"
                assert literal in parsed.text, f"original literal not preserved: {url}: {parsed.text}"
                line, col, _ = check.position(source.read_text(), literal)
                assert f"HTML subset at {line}:{col + 1}:" in diagnostics, diagnostics
                assert output.is_file()
                assert f"HTML subset at {line}:{col + 1}:" in experimental.stderr_path.read_text(), "worker omitted fallback diagnostic"
                new_trace = image_trace.read_bytes()[len(before_image_trace):].decode()
                if url == "truncated.png":
                    assert new_trace.count("DECODE\t") == 2, "truncated PNG did not exercise worker and inspection decoder failures"
                else:
                    assert "DECODE\t" not in new_trace, "refused URL/header reached decoder"
                observations.append({"src": url, "fallback": "escaped-original", "diagnostic": diagnostics.strip()})
                render(check.document('<img src="small.png" alt="recovered">'))
            literals = [f'<img src="budget-{letter}.png" alt="budget">' for letter in "abc"]
            render(check.document("\n\n".join(literals)))
            parsed, diagnostics, _ = inspect(source)
            assert parsed.tags.count("img") == 2 and literals[2] in parsed.text, "32Mi retained-pixel budget not enforced"
            assert "HTML subset at " in diagnostics
            observations.append({"retained_pixel_budget": "third distinct 12Mi-pixel image declined"})
            # A second DRAW of an already loaded layout must have identical pixels.
            before_load = image_trace.read_bytes()
            first, _ = render(check.document('<img src="small.png" alt="repeat"> <img src="small.png" alt="repeat">'))
            attempts = image_trace.read_bytes()[len(before_load):].decode()
            assert attempts.count("DECODE\t") == 1, "successful image not cached per layout"
            trace_before = image_trace.read_bytes()
            second = directory / "repeat.png"
            experimental.draw(second)
            equal(first, second)
            added = image_trace.read_bytes()[len(trace_before):].decode()
            assert "DECODE\t" not in added, "DRAW decoded an image"
            before_load = image_trace.read_bytes()
            render(check.document('<img src="truncated.png"> <img src="truncated.png">'))
            attempts = image_trace.read_bytes()[len(before_load):].decode()
            assert attempts.count("DECODE\t") == 1, "failed image retried within one layout"
            observations.append({"same_worker_recovery": True, "repeat_draw": "pixel-identical-no-decode"})
        finally:
            experimental.close()
            stock.close()
            if previous_trace is None:
                os.environ.pop("MDVIEW_HTML_IMAGE_TRACE", None)
            else:
                os.environ["MDVIEW_HTML_IMAGE_TRACE"] = previous_trace
    OBSERVED.write_text(json.dumps({"checks": observations, "production_worker": str(STOCK)}, indent=2, ensure_ascii=False) + "\n")
    print(f"PASS: local HTML images, stock Markdown pixel/dimension parity, policy/fallback/budgets/recovery; {OBSERVED}")


if __name__ == "__main__":
    main()
