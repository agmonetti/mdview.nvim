#!/usr/bin/env python3
"""Native HTML-table raster, source-position and fallback regression."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "build/mdview-preview"
CSS = ROOT / "styles/markdown.css"


def hexpath(path):
    return str(path).encode().hex()


def run(*args, input=None):
    result = subprocess.run(args, input=input, text=True, capture_output=True, check=True)
    return result.stdout, result.stderr


def render(path, width, output):
    command = f"LOAD 1 {width} {hexpath(path)} {hexpath(path.parent)} {hexpath(CSS)}\n"
    command += f"DRAW 1 1 0 0 0 800 {hexpath(output)}\nQUIT\n"
    stdout, stderr = run(str(BINARY), input=command)
    assert "READY 1 " in stdout and "FRAME 1 1 " in stdout and "ERROR " not in stdout, (stdout, stderr)
    return stdout


def html(path, mode="plain"):
    return run(str(BINARY), "--html", str(path), str(CSS), mode)


with tempfile.TemporaryDirectory(prefix="mdview-html-tables-") as directory:
    folder = Path(directory)
    wrap_rows = {}
    for width in (300, 700):
        fixture = folder / "table.md"
        fixture.write_text("""# Before

<table class="discard" onclick="bad()">
<caption>Résumé &amp; status</caption>
<thead><tr><th colspan="2">Full heading</th></tr></thead>
<tbody>
<tr><td rowspan="2">Tall cell</td><td><strong>First value</strong></td></tr>
<tr><td>Second value with a lengthy sequence of words to wrap in a narrow pane.</td></tr>
</tbody>
<tfoot><tr><td>Footer left</td><td>Footer right</td></tr></tfoot>
</table>

# After
""")
        plain, diagnostics = html(fixture)
        marked, marked_diagnostics = html(fixture, "marked")
        assert not diagnostics and not marked_diagnostics, (diagnostics, marked_diagnostics)
        assert '<table data-mdview=' in marked and '<th colspan="2"' in marked and '<td rowspan="2"' in marked
        assert 'onclick=' not in plain and 'class="discard"' not in plain
        for text in ("Résumé &amp; status", "First value", "Second value", "Footer right", "After"):
            assert text in plain and text in marked, text
        rasters = []
        for mode, converted in (("plain", plain), ("marked", marked)):
            source_html = folder / f"{mode}-{width}.html"
            source_html.write_text(converted)
            raster_width = max(320, width)
            source_html.with_suffix(".html.cfg").write_text(f"bestfit: false\nwidth: {raster_width}\nheight: 800\n")
            raster = folder / f"{mode}-{width}.png"
            run(str(ROOT / "build/mdview-render"), str(source_html), str(raster), str(raster_width))
            rasters.append(raster)
        parity = subprocess.run(("magick", "compare", "-metric", "AE", *rasters, "null:"),
                                text=True, capture_output=True)
        assert parity.returncode == 0 and parity.stderr.startswith("0 "), (width, parity.stderr)
        frame = folder / "table.png"
        protocol = render(fixture, width, frame)
        anchors = [(int(line), int(first), int(last), float(y)) for line, first, last, y in
                   re.findall(r"^FRAG (\d+) (\d+) (\d+) ([\d.]+)$", protocol, re.M)]
        def position(token):
            offset = fixture.read_text().index(token)
            prefix = fixture.read_text()[:offset]
            line = prefix.count("\n") + 1
            column = len(prefix.rsplit("\n", 1)[-1].encode())
            return line, column
        def anchor(token):
            line, column = position(token)
            matches = [y for row, first, last, y in anchors if row == line and first <= column <= last]
            assert matches, (width, token, anchors)
            return matches[0]
        assert anchor("Résumé") < anchor("Full heading") < anchor("Tall cell")
        assert anchor("First value") < anchor("Second value")
        assert anchor("First value") < anchor("Tall cell") < anchor("Footer right")
        assert anchor("Second value") < anchor("Footer right") < anchor("After")
        wrap_rows[width] = len({y for row, _, _, y in anchors if row == 8})
        assert frame.is_file()
    assert wrap_rows[300] > wrap_rows[700] >= 2, wrap_rows

    # Stock cmark GFM table and independently sanitized HTML table must rasterize
    # identically with the same stylesheet and visible content.
    html_table = folder / "simple-html.md"
    gfm_table = folder / "simple-gfm.md"
    html_table.write_text("# Before\n\n<table>\n<thead><tr><th>Label</th><th>Value</th></tr></thead>\n"
                          "<tbody><tr><td>Alpha</td><td>café</td></tr></tbody>\n</table>\n\n# After\n")
    gfm_table.write_text("# Before\n\n| Label | Value |\n| --- | --- |\n| Alpha | café |\n\n# After\n")
    for width in (300, 700):
        html_frame = folder / f"html-{width}.png"
        gfm_frame = folder / f"gfm-{width}.png"
        render(html_table, width, html_frame)
        render(gfm_table, width, gfm_frame)
        comparison = subprocess.run(("magick", "compare", "-metric", "AE", html_frame, gfm_frame, "null:"),
                                    text=True, capture_output=True)
        assert comparison.returncode == 0 and comparison.stderr.startswith("0 "), (width, comparison.stderr)

    for name, body in {
        "orphan-cell": "<td>Orphan</td>",
        "missing-row": "<table><td>Orphan</td></table>",
        "bad-span": "<table><tr><td colspan=65>Bad</td></tr></table>",
        "duplicate-span": '<table><tr><td rowspan="2" rowspan="3">Bad</td></tr></table>',
        "direct-text": "<table>Unsafe<tr><td>Good</td></tr></table>",
        "resource": "<table><tr><td><script>bad()</script></td></tr></table>",
    }.items():
        fixture = folder / (name + ".md")
        fixture.write_text("# Before\n\n" + body + "\n\n# After\n")
        converted, diagnostic = html(fixture)
        assert "HTML subset at " in diagnostic, (name, diagnostic)
        assert "&lt;" in converted and "<h1>After</h1>" in converted, name
        protocol = render(fixture, 420, folder / (name + ".png"))
        assert "FRAG 5 " in protocol, (name, protocol)

    nested = folder / "nested.md"
    nested.write_text("# Top\n\n<details><summary>Rows</summary>\n\n"
                      "<table><tr><th>Heading</th></tr><tr><td>Inner value</td></tr></table>\n\n"
                      "</details>\n\n# Bottom\n")
    frames = [folder / f"detail-{revision}.png" for revision in (1, 2, 3)]
    request = f"LOAD 1 700 {hexpath(nested)} {hexpath(folder)} {hexpath(CSS)}\n"
    for revision, state in ((1, None), (2, 0), (3, 1)):
        if state is not None:
            request += f"TOGGLE {revision} 0 {state}\n"
        request += f"DRAW {revision} {revision} 0 0 0 420 {hexpath(frames[revision-1])}\n"
    output, diagnostic = run(str(BINARY), input=request + "QUIT\n")
    assert not diagnostic and "ERROR " not in output, (output, diagnostic)
    phases = re.split(r"READY [123] 700 [\d.]+ [\d.]+\n", output)
    assert len(phases) == 4, output
    visible_cell = lambda phase: bool(re.search(r"^FRAG 5 (?!0 0 )\d+ \d+ ", phase, re.M))
    assert visible_cell(phases[0]) and not visible_cell(phases[1]) and visible_cell(phases[2]), output
    restored = subprocess.run(("magick", "compare", "-metric", "AE", frames[0], frames[2], "null:"),
                              text=True, capture_output=True)
    assert restored.returncode == 0 and restored.stderr.startswith("0 "), restored.stderr
    collapsed = subprocess.run(("magick", "compare", "-metric", "AE", frames[0], frames[1], "null:"),
                               text=True, capture_output=True)
    assert collapsed.returncode == 1 and not collapsed.stderr.startswith("0 "), collapsed.stderr

print("HTML table native regression passed")
