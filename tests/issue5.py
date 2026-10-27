"""Cross-line inline code: run after building, with python3 tests/issue5.py."""
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREVIEW = ROOT / "build/mdview-preview"
RENDER = ROOT / "build/mdview-render"
CSS = ROOT / "styles/markdown.css"


def run(args, *, stdin=None):
    result = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout


def h(value):
    return str(value).encode().hex()


# Expected physical byte offsets of code continuation, following text and next heading.
CASES = {
    "list": (b"# PRE\n\n1. Item with `two\n   lines of code` tail.\n\n# POST\n",
             [(4, 3, "lines"), (4, 18, "tail"), (6, 2, "POST")]),
    "tabs-crlf": (b"# PRE\r\n\r\n> 1. P `codeAAA\r\n>\tcodeBBB` tailXYZ.\r\n\r\n# POST\r\n",
                  [(4, 2, "codeBBB"), (4, 11, "tailXYZ"), (6, 2, "POST")]),
    "hardbreak": (b"Text `multiline\ncode` line 1\\\nline 2 tail `next\ncode` done\n\n# POST\n",
                  [(2, 0, "code"), (3, 0, "line"), (4, 0, "code"), (6, 2, "POST")]),
    "html": (b"Text <span\n class='x'>word</span> `multi\ncode` &amp; \\* tail\n\n# POST\n",
             [(2, 11, "word"), (3, 0, "code"), (3, 6, "&"), (5, 2, "POST")]),
    "html-after": (b"Text `multi\ncode` <span\n class='x'>word</span> line 1\\\nline 2 tail\n\n# POST\n",
                   [(2, 0, "code"), (3, 11, "word"), (4, 0, "line"), (6, 2, "POST")]),
    "setext": (b"# PRE\n\nP `codeAAA\ncodeBBB` tailXYZ.\n----\n\n# POST\n",
               [(4, 0, "codeBBB"), (4, 9, "tailXYZ"), (7, 2, "POST")]),
    "repeat": (b"Text `multiline\ncode` line 1\\\nline 2 tail `multiline\ncode` again\n\n# POST\n",
               [(2, 0, "code"), (3, 13, "multiline"), (4, 0, "code"), (6, 2, "POST")]),
    "image-link": (b"Text `multi\ncode` ![photo](local%20image.png) next <https://example.invalid>\n\n# POST\n",
                   [(2, 0, "code"), (2, 34, "next"), (2, 40, "https"), (4, 2, "POST")]),
    "generated-link": (b"Text `multi\ncode` www.example.com after\n\n# POST\n",
                       [(2, 0, "code"), (2, 22, "after"), (4, 2, "POST")]),
    "ordinary": (b"P `one` end\\\nnext line\n\n# POST\n",
                 [(4, 2, "POST")]),
    "ordinary-soft": (b"> 1. P `one` end\n>    next line\n\n# POST\n",
                      [(2, 5, "next"), (4, 2, "POST")]),
}


def main():
    with tempfile.TemporaryDirectory(prefix="mdview-issue5-") as scratch:
        directory = Path(scratch)
        shutil.copyfile(ROOT / "tests/html/assets/local café.png", directory / "local image.png")
        for name, (source, expected) in CASES.items():
            path = directory / f"{name}.md"
            path.write_bytes(source)
            for enabled in (True, False):
                if not enabled and name in ("html", "html-after"):
                    disabled = subprocess.run([PREVIEW, "--html", path, CSS, "marked", "html=0"],
                                              capture_output=True, text=True, timeout=20)
                    assert disabled.returncode and "Raw HTML" in disabled.stderr
                    continue
                option = "" if enabled else " html=0"
                for width in (320, 700):
                    rgba = directory / f"{name}-{enabled}-{width}.rgba"
                    request = f"LOAD 1 {width} {h(path)} {h(directory)} {h(CSS)}{option}\n"
                    request += f"DRAW 1 1 0 0 0 400 {h(rgba)}\nQUIT\n"
                    response = run([PREVIEW], stdin=request)
                    assert "READY 1" in response and "FRAME 1 1" in response and "ERROR " not in response, response
                    if name == "ordinary":
                        assert "WARN " in response and "FRAG 2 " not in response, response
                    elif name == "generated-link":
                        assert "WARN 1 2 2 " in response and "FRAG 2 0 0 " in response
                        assert "FRAG 2 6 " not in response, response
                    else:
                        assert "WARN " not in response, (name, response)
                    fragments = [tuple(map(float, row.split()[1:5])) for row in response.splitlines()
                                 if row.startswith("FRAG ")]
                    if name == "image-link":
                        assert any(int(f[0]) == 2 and int(f[1]) == 0 and int(f[2]) == 0 for f in fragments), response
                    for line, col, token in expected:
                        assert source.splitlines()[line-1][col:col+len(token)] == token.encode(), (name, line, col, token)
                        assert any(int(f[0]) == line and int(f[1]) == col for f in fragments), (name, width, line, col, fragments)
                    pixels = []
                    for mode in ("plain", "marked"):
                        html = run([PREVIEW, "--html", path, CSS, mode] + ([] if enabled else ["html=0"]))
                        html_path = directory / f"{name}-{enabled}-{width}-{mode}.html"
                        html_path.write_text(html)
                        html_path.with_suffix(".html.cfg").write_text(f"bestfit: false\nwidth: {width}\nheight: 400\n")
                        png = html_path.with_suffix(".png")
                        run([RENDER, html_path, png, str(width)])
                        raw = subprocess.run(["magick", png, "-depth", "8", "RGBA:-"], capture_output=True, timeout=20)
                        assert raw.returncode == 0, raw.stderr
                        pixels.append(raw.stdout)
                    assert pixels[0] == pixels[1] == rgba.read_bytes(), (name, enabled, width, "raster parity")
    print("PASS: multiline code byte anchors, HTML opt-out, CRLF/tabs/hardbreak and pixel parity")


if __name__ == "__main__":
    main()
