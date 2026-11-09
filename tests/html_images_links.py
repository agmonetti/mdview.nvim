"""Regression test for HTML subset percentage image width and <a> link support."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREVIEW = ROOT / "build/mdview-preview"
CSS = ROOT / "styles/markdown.css"


def h(value):
    return str(value).encode().hex()


def run(args, *, stdin=None):
    result = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout, result.stderr


def main():
    with tempfile.TemporaryDirectory(prefix="mdview-html-test-") as scratch:
        directory = Path(scratch)
        assets = directory / "assets"
        assets.mkdir()
        # Create small test PNGs
        img_cmd = ["magick", "-size", "100x100", "xc:blue", str(assets / "welcome.png")]
        subprocess.run(img_cmd, check=True)
        img_cmd2 = ["magick", "-size", "100x100", "xc:red", str(assets / "main.png")]
        subprocess.run(img_cmd2, check=True)

        # Snippet from mcTUI issue
        mctui_md = (
            '<h1 align="center">mcTUI</h1>\n\n'
            '<p align="center">\n'
            '  <img src="assets/welcome.png" alt="mcTUI welcome screen" width="48%">\n'
            '  <img src="assets/main.png" alt="mcTUI terminal interface" width="48%">\n'
            '</p>\n\n'
            '<p align="center">\n'
            '  A terminal launcher for Minecraft.<br>\n'
            '  <strong>Accounts | Instances</strong><br>\n'
            '</p>\n\n'
            '<p align="center">\n'
            '  <a href="https://example.com/docs">Documentation</a> |\n'
            '  <a href="https://example.com/releases">Latest release</a>\n'
            '</p>\n'
        )

        md_path = directory / "test.md"
        md_path.write_text(mctui_md)

        # Test HTML export via preview --html
        html_out, html_err = run([str(PREVIEW), "--html", str(md_path), str(CSS), "marked"])
        assert "malformed img" not in html_err, f"Unexpected image error: {html_err}"
        assert "unsupported or malformed HTML" not in html_err, f"Unexpected html error: {html_err}"
        assert 'style="width:48%;height:auto"' in html_out, f"Missing percentage width style: {html_out}"
        assert 'href="https://example.com/docs"' in html_out, f"Missing doc link: {html_out}"
        assert 'href="https://example.com/releases"' in html_out, f"Missing release link: {html_out}"

        # Test worker protocol LOAD and FRAG positions
        req = f"LOAD 1 900 {h(md_path)} {h(directory)} {h(CSS)}\nQUIT\n"
        stdout, stderr = run([str(PREVIEW)], stdin=req)
        assert "READY 1" in stdout, f"LOAD failed to become READY:\n{stdout}\nstderr:\n{stderr}"
        assert "ERROR " not in stdout, f"LOAD returned error:\n{stdout}"

        # Check line anchors for images (lines 4, 5) and links (lines 14, 15)
        frags = {}
        for line in stdout.splitlines():
            if line.startswith("FRAG "):
                parts = line.split()
                line_no = int(parts[1])
                frags.setdefault(line_no, []).append(parts)

        assert 4 in frags, "Missing fragment anchor for image on line 4"
        assert 5 in frags, "Missing fragment anchor for image on line 5"
        assert 14 in frags, "Missing fragment anchor for link on line 14"
        assert 15 in frags, "Missing fragment anchor for link on line 15"

        # Test unsafe javascript link is rejected and escaped
        unsafe_md = '<p><a href="javascript:alert(1)">Dangerous</a></p>\n'
        unsafe_path = directory / "unsafe.md"
        unsafe_path.write_text(unsafe_md)
        out_unsafe, err_unsafe = run([str(PREVIEW), "--html", str(unsafe_path), str(CSS), "marked"])
        assert "&lt;a href=&quot;javascript:alert(1)&quot;&gt;" in out_unsafe
        assert "HTML subset at" in err_unsafe

    print("PASS: html percentage image width and <a> link support regression")


if __name__ == "__main__":
    main()
