#!/usr/bin/env python3
"""Sanitized underline pixels, wrapping, source anchors and fallback."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PREVIEW = ROOT / "build/mdview-preview"
RENDER = ROOT / "build/mdview-render"
CSS = ROOT / "styles/markdown.css"


def run(*args, input=None):
    return subprocess.run(args, input=input, text=True, capture_output=True)


def convert(path, mode="plain"):
    result = run(str(PREVIEW), "--html", str(path), str(CSS), mode)
    assert result.returncode == 0, result.stderr
    return result.stdout, result.stderr


def frame(path, width, output):
    hexpath = lambda p: str(p).encode().hex()
    commands = (f"LOAD 1 {width} {hexpath(path)} {hexpath(path.parent)} {hexpath(CSS)}\n"
                f"DRAW 1 1 0 0 0 800 {hexpath(output)}\nQUIT\n")
    result = run(str(PREVIEW), input=commands)
    assert result.returncode == 0 and "READY 1 " in result.stdout and "FRAME 1 1 " in result.stdout, result
    return result.stdout, result.stderr


def pixels_differ(left, right):
    result = run("magick", "compare", "-metric", "AE", str(left), str(right), "null:")
    count = re.match(r"\d+", result.stderr)
    assert count, result.stderr
    return int(count.group())


with tempfile.TemporaryDirectory(prefix="mdview-underline-") as temp:
    folder = Path(temp)
    text = ("It is important to separate **latency** and **response time**.\n"
            "- <u>Response time: </u> is what the client sees; it includes network delays and queueing delays.\n"
            "- <u>Latency: </u> is the duration a request waits to be handled, while it is **latent**.\n"
            "- <u><strong>Nested label</strong> and more words that wrap onto another row at narrow widths</u> tail.\n"
            "\n# After\n")
    source = folder / "underlined.md"
    source.write_text(text)
    control = folder / "control.md"
    control.write_text(text.replace("<u>", "<span>").replace("</u>", "</span>"))
    for width in (320, 700):
        rasters = []
        for mode in ("plain", "marked"):
            converted, diagnostic = convert(source, mode)
            assert not diagnostic and converted.count("<u") == 4 and "&lt;u&gt;" not in converted, diagnostic
            assert "<strong>" in converted and "Nested label" in converted
            html = folder / f"{mode}-{width}.html"
            html.write_text(converted)
            html.with_suffix(".html.cfg").write_text(f"bestfit: false\nwidth: {width}\nheight: 800\n")
            png = folder / f"{mode}-{width}.png"
            result = run(str(RENDER), str(html), str(png), str(width))
            assert result.returncode == 0, result.stderr
            rasters.append(png)
        assert pixels_differ(*rasters) == 0, "source attribution changed underline pixels"
        native = folder / f"native-{width}.png"
        protocol, diagnostic = frame(source, width, native)
        assert not diagnostic, diagnostic
        anchors = [(int(line), int(first), int(last), float(y)) for line, first, last, y in
                   re.findall(r"^FRAG (\d+) (\d+) (\d+) ([\d.]+)$", protocol, re.M)]
        for line, token in ((2, "Response time:"), (3, "Latency:"), (4, "Nested label"), (4, "another row"), (6, "After")):
            column = len(text.splitlines()[line-1].split(token, 1)[0].encode())
            assert any(row == line and first <= column <= last for row, first, last, _ in anchors), (width, token, anchors)
        if width == 320:
            assert len({y for line, _, _, y in anchors if line == 4}) > 1, "underlined line did not wrap"
        plain_control = folder / f"control-{width}.png"
        control_protocol, control_diagnostic = frame(control, width, plain_control)
        assert not control_diagnostic, control_diagnostic
        control_y = [float(y) for y in re.findall(r"^FRAG 6 \d+ \d+ ([\d.]+)$", control_protocol, re.M)]
        underline_y = [y for line, _, _, y in anchors if line == 6]
        assert underline_y == control_y, (width, underline_y, control_y)
        assert pixels_differ(native, plain_control) > 0, "underline has no raster effect"

    invalid = folder / "invalid.md"
    invalid.write_text("<u>Unclosed\n\n# Following\n")
    converted, diagnostic = convert(invalid)
    assert "&lt;u&gt;Unclosed" in converted and "<h1>Following</h1>" in converted, (converted, diagnostic)
    assert "unclosed HTML tag" in diagnostic, diagnostic
    stripped = folder / "stripped.md"
    stripped.write_text('<u style="color:red" onclick="bad()">Safe</u>\n')
    converted, diagnostic = convert(stripped)
    assert not diagnostic and "<u>Safe</u>" in converted and "color:red" not in converted and "onclick" not in converted
    disabled = run(str(PREVIEW), "--html", str(source), str(CSS), "plain", "html=0")
    assert disabled.returncode != 0 and "Raw HTML" in disabled.stderr, disabled

print("PASS: underline pixels, marked/plain parity, wrapped source anchors, invalid fallback and html=false")
