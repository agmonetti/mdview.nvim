#!/usr/bin/env python3
"""Production HTML image sizing: real LOAD geometry and DRAW pixels, no Kitty display."""
from pathlib import Path
import subprocess
import tempfile

import check
from images_check import png

check.BINARY = check.ROOT / "build/mdview-preview"
COLOR = bytes((53, 146, 199, 255))


def image_box(path, width):
    raw = subprocess.run(["magick", str(path), "-depth", "8", "rgba:-"],
                         capture_output=True, check=True, timeout=30).stdout
    assert len(raw) % (width * 4) == 0
    pixels = (raw[i:i + 4] for i in range(0, len(raw), 4))
    points = [(n % width, n // width) for n, pixel in enumerate(pixels) if pixel == COLOR]
    assert points, "sized image missing from native raster"
    left, right = min(x for x, _ in points), max(x for x, _ in points)
    top, bottom = min(y for _, y in points), max(y for _, y in points)
    return right - left + 1, bottom - top + 1


def run():
    assert check.BINARY.is_file(), "build native preview first"
    with tempfile.TemporaryDirectory(prefix="mdview-dimensions-") as temp:
        directory = Path(temp)
        png(directory / "wide.png", 1200, 60)
        png(directory / "tall.png", 60, 1200)
        png(directory / "oversize.png", 8193, 1)
        source = directory / "source.md"
        worker = check.Worker(directory, directory / "trace")
        try:
            for width in (240, 420, 760):
                for name, attributes, expected in (
                    ("wide", 'width="120"', (120, 6)),
                    ("wide", 'height="120"', (width - 96, None)),
                    ("wide", 'width="120" height="120"', (120, 6)),
                    ("tall", 'height="120"', (6, 120)),
                    ("tall", 'width="120" height="120"', (6, 120)),
                    ("tall", 'width="120"', (120, 2400)),
                    ("tall", 'width="2000" height="30"', (1, 20)),
                ):
                    literal = f'<img src="{name}.png" {attributes}>'
                    source.write_text(check.document(literal))
                    fragments = worker.load(source, check.CSS, width, directory)
                    assert any(row[0] == 3 and row[1] <= 0 <= row[2] for row in fragments), "image lost source anchor"
                    following = min(row[3] for row in fragments if row[0] == 5)
                    output = directory / "viewport.png"
                    worker.draw(output)
                    box = image_box(output, width)
                    assert box[0] == expected[0] and (expected[1] is None or box[1] == expected[1]), (width, literal, box)
                    assert abs(box[1] - box[0] * (60 / 1200 if name == "wide" else 1200 / 60)) <= 1, (literal, box)
                    assert following > box[1], "following heading did not reflow"
                for body in ('before <img src="wide.png" width="120" height="120"> after',
                             '<details><summary>Image</summary>\n<img src="wide.png" width="120" height="120">\n</details>'):
                    source.write_text(check.document(body))
                    rows = worker.load(source, check.CSS, width, directory)
                    output = directory / "nested.png"
                    worker.draw(output)
                    assert image_box(output, width) == (120, 6), (width, body)
                    if body.startswith("<details>"):
                        after_line = source.read_text().splitlines().index("# POST001") + 1
                        before = min(row[3] for row in rows if row[0] == after_line)
                        closed = worker.request(f"TOGGLE {worker.revision + 1} 0 0", "READY")
                        worker.revision += 1
                        closed_fragments = [row.split() for row in closed if row.startswith("FRAG ")]
                        after = min(float(row[4]) for row in closed_fragments if int(row[1]) == after_line)
                        assert after < before, "closing details did not remove sized image space"
                        reopened = worker.request(f"TOGGLE {worker.revision + 1} 0 1", "READY")
                        worker.revision += 1
                        reopened_fragments = [row.split() for row in reopened if row.startswith("FRAG ")]
                        assert min(float(row[4]) for row in reopened_fragments if int(row[1]) == after_line) == before
                        restored = directory / "restored.png"
                        worker.draw(restored)
                        assert restored.read_bytes() == output.read_bytes(), "details reopen changed sized pixels"
                # An invalid request is literal, diagnosed at original byte position; correction recovers in the same worker.
                for value in ('0', '-1', '5%', 'auto', '1.5', '4097', '9999999999999999999999', ''):
                    literal = f'<img src="wide.png" width="{value}">'
                    source.write_text(check.document(literal))
                    worker.load(source, check.CSS, width, directory)
                    html = subprocess.run([str(check.BINARY), '--html', str(source), str(check.CSS), 'plain'],
                                          capture_output=True, text=True, check=True, timeout=30)
                    assert '&lt;img' in html.stdout and 'HTML subset at 3:1:' in html.stderr, value
                for literal in ('<img src="oversize.png" width="1" height="1">',
                                '<img src="wide.png" width="120" width="120">',
                                '<img src="tall.png" height="1">'):
                    source.write_text(check.document(literal))
                    worker.load(source, check.CSS, width, directory)
                    html = subprocess.run([str(check.BINARY), '--html', str(source), str(check.CSS), 'plain'],
                                          capture_output=True, text=True, check=True, timeout=30)
                    assert '&lt;img' in html.stdout and 'HTML subset at 3:1:' in html.stderr
                source.write_text(check.document('<img src="wide.png" width="120px">'))
                worker.load(source, check.CSS, width, directory)
                output = directory / 'recovered.png'
                worker.draw(output)
                assert image_box(output, width) == (120, 6)
        finally:
            worker.close()
    print('PASS: production HTML image sizing, intrinsic safety, source anchors, reflow, fallback and recovery')


if __name__ == '__main__':
    run()
