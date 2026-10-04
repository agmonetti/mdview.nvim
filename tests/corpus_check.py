#!/usr/bin/env python3
"""Batch-check versioned fixtures and a local Markdown corpus.

Run after ``scripts/build.sh``:
    python3 tests/corpus_check.py
    python3 tests/corpus_check.py /path/to/markdown-corpus

Local ``*.md`` files are discovered recursively. The default optional corpus is
``tests/corpus-local/``; versioned ``tests/fixtures/*.md`` are always included.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREVIEW = ROOT / "build/mdview-preview"
RENDER = ROOT / "build/mdview-render"
CSS = ROOT / "styles/markdown.css"
FIXTURES = ROOT / "tests/fixtures"
DEFAULT_CORPUS = ROOT / "tests/corpus-local"
REPORT_NAME = "corpus-report.json"
WIDTH = 900
VIEW_HEIGHT = 600
TIMEOUT = 45
FRAG = re.compile(r"^FRAG (\d+) (\d+) (\d+) ([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)$", re.M)
READY = re.compile(r"^READY 1 (\d+) ([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?) ([^\s]+)$", re.M)
FRAME = re.compile(r"^FRAME 1 1 \d+ \d+ (\d+) (\d+) (\d+) [^\s]+$", re.M)
EXPECTED_ANCHORS = {"autolink-email.md": (3, 9, 18)}


class CorpusFailure(Exception):
    pass


def run(command, *, input_text=None, timeout=TIMEOUT):
    try:
        result = subprocess.run(
            [str(arg) for arg in command], input=input_text, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
            cwd=ROOT, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise CorpusFailure(f"timeout after {error.timeout}s: {command[0]}") from error
    if result.returncode < 0:
        raise CorpusFailure(f"process terminated by signal {-result.returncode}: {command[0]}")
    return result


def png_size(path):
    with path.open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise CorpusFailure(f"invalid PNG header: {path}")
    width, height = struct.unpack(">II", header[16:24])
    if width < 1 or height < 1:
        raise CorpusFailure(f"invalid PNG dimensions {width}x{height}: {path}")
    if width > 32767 or height > 32767:
        raise CorpusFailure(f"PNG dimensions exceed Cairo surface bounds: {width}x{height}")
    return width, height


def worker_run(source, output):
    request = (
        f"LOAD 1 {WIDTH} {source.as_posix().encode().hex()} "
        f"{source.parent.as_posix().encode().hex()} {CSS.as_posix().encode().hex()}\n"
        f"DRAW 1 1 0 0 0 {VIEW_HEIGHT} {output.as_posix().encode().hex()}\n"
        "QUIT\n"
    )
    result = run([PREVIEW], input_text=request)
    if result.returncode != 0:
        raise CorpusFailure(f"worker exited {result.returncode}: {result.stderr.strip()}")
    if "ERROR " in result.stdout:
        raise CorpusFailure(f"worker protocol error: {result.stdout.strip()}")
    ready = READY.search(result.stdout)
    frame = FRAME.search(result.stdout)
    fragments = FRAG.findall(result.stdout)
    if not ready or not frame:
        raise CorpusFailure("missing READY or FRAME output")
    width, height = map(int, frame.groups()[1:])
    if (width, height) != (WIDTH, VIEW_HEIGHT):
        raise CorpusFailure(f"unexpected viewport dimensions {width}x{height}")
    doc_height = float(ready.group(2))
    if not math.isfinite(doc_height) or doc_height <= 0:
        raise CorpusFailure(f"invalid document height {doc_height}")
    raw_lines = source.read_bytes().splitlines()
    checked = []
    for line_text, column_text, end_text, y_text in fragments:
        line, column, end, y = int(line_text), int(column_text), int(end_text), float(y_text)
        if not 1 <= line <= len(raw_lines):
            raise CorpusFailure(f"FRAG line {line} outside source ({len(raw_lines)} lines)")
        length = len(raw_lines[line - 1])
        if column > length or end > length or column > end:
            raise CorpusFailure(f"FRAG {line}:{column}-{end} outside {length}-byte source line")
        # cmark/native source columns are byte offsets; an inclusive end may point
        # at a UTF-8 continuation byte when the rendered token contains Unicode.
        if not math.isfinite(y) or y < 0 or y > doc_height + 1:
            raise CorpusFailure(f"FRAG {line}:{column} has invalid layout y={y} for {doc_height}px")
        checked.append((line, column, end, y_text))
    warnings = tuple(line for line in result.stderr.splitlines() if line.strip())
    return tuple(checked), hashlib.sha256(output.read_bytes()).hexdigest(), warnings


def check_document(source, scratch):
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", source.name)
    html_path = scratch / f"{slug}.html"
    rendered = []
    anchor_runs = []
    viewport_hashes = []
    diagnostics = set()
    for repetition in (1, 2):
        converted = run([PREVIEW, "--html", source, CSS, "marked"])
        if converted.returncode != 0:
            raise CorpusFailure(f"Markdown conversion exited {converted.returncode}: {converted.stderr.strip()}")
        diagnostics.update(line for line in converted.stderr.splitlines() if line.strip())
        html_path.write_text(converted.stdout, encoding="utf-8")
        png = scratch / f"{slug}-full-{repetition}.png"
        cfg_path = Path(str(html_path) + ".cfg")
        cfg_path.write_text(f"bestfit: false\nwidth: {WIDTH}\n", encoding="utf-8")
        native = run([RENDER, html_path, png, WIDTH])
        if native.returncode != 0:
            raise CorpusFailure(f"standalone renderer exited {native.returncode}: {native.stderr.strip()}")
        png_dimensions = png_size(png)
        if png_dimensions[0] != WIDTH:
            raise CorpusFailure(f"standalone PNG width {png_dimensions[0]} does not match {WIDTH}px layout")
        rendered.append(hashlib.sha256(png.read_bytes()).hexdigest())
        viewport = scratch / f"{slug}-viewport-{repetition}.png"
        anchors, image_hash, warnings = worker_run(source, viewport)
        anchor_runs.append(anchors)
        viewport_hashes.append(image_hash)
        diagnostics.update(warnings)
        if png_size(viewport) != (WIDTH, VIEW_HEIGHT):
            raise CorpusFailure("worker output dimensions do not match requested viewport")
        crop = scratch / f"{slug}-crop-{repetition}.png"
        cropped = run(["magick", png, "-background", "#0d1117", "-gravity", "northwest",
                       "-extent", f"{WIDTH}x{VIEW_HEIGHT}", crop])
        if cropped.returncode != 0:
            raise CorpusFailure(f"cannot crop standalone PNG: {cropped.stderr.strip()}")
        parity = run(["magick", "compare", "-metric", "AE", crop, viewport, "null:"])
        if parity.returncode != 0:
            raise CorpusFailure(f"CLI/worker pixel desync: {parity.stderr.strip()}")
    if rendered[0] != rendered[1]:
        raise CorpusFailure("standalone PNG generation is not deterministic")
    if viewport_hashes[0] != viewport_hashes[1]:
        raise CorpusFailure("worker viewport PNG generation is not deterministic")
    if anchor_runs[0] != anchor_runs[1]:
        raise CorpusFailure("FRAG source anchors differ between clean worker runs")
    expected = EXPECTED_ANCHORS.get(source.name) if source.parent.resolve() == FIXTURES.resolve() else None
    if expected and not any(anchor[:3] == expected for anchor in anchor_runs[0]):
        raise CorpusFailure(f"expected source anchor {expected} missing")
    return len(anchor_runs[0]), png_dimensions, tuple(sorted(diagnostics))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", nargs="?", type=Path, default=DEFAULT_CORPUS,
                        help=f"optional local corpus directory (default: {DEFAULT_CORPUS})")
    args = parser.parse_args()
    for binary in (PREVIEW, RENDER):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            parser.error(f"required executable missing: {binary}; run ./scripts/build.sh")
    if not CSS.is_file():
        parser.error(f"stylesheet missing: {CSS}")
    if shutil.which("magick") is None:
        parser.error("ImageMagick `magick` is required for worker/CLI pixel comparison")

    fixtures = sorted(FIXTURES.glob("*.md"))
    if not fixtures:
        parser.error(f"no versioned Markdown fixtures found in {FIXTURES}")
    fixture_paths = {path.resolve() for path in fixtures}
    local = sorted(args.corpus.rglob("*.md")) if args.corpus.is_dir() else []
    sources = fixtures + [path for path in local if path.resolve() not in fixture_paths]
    failures = []
    warnings = []
    passed = 0
    with tempfile.TemporaryDirectory(prefix="mdview-corpus-check-") as temporary:
        scratch = Path(temporary)
        for index, source in enumerate(sources, 1):
            try:
                anchors, dimensions, diagnostics = check_document(source.resolve(), scratch)
                passed += 1
                if diagnostics:
                    warnings.append({"source": str(source), "messages": diagnostics})
                if index % 100 == 0:
                    print(f"Progress: {index}/{len(sources)} documents", flush=True)
            except (CorpusFailure, OSError, ValueError) as error:
                failures.append({"source": str(source), "error": str(error)})
                print(f"FAIL {source} — {error}", flush=True)
    summary = {
        "documents": len(sources), "passed": passed, "failed": len(failures),
        "local_documents": len(local), "versioned_fixtures": len(fixtures),
        "warning_documents": len(warnings), "failures": failures, "warnings": warnings,
    }
    report_path = args.corpus / REPORT_NAME
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Corpus: {passed}/{len(sources)} passed, {len(failures)} failed; {len(local)} local documents, {len(fixtures)} fixtures; {len(warnings)} documents emitted fallback diagnostics")
    print(f"Per-document failures and fallback diagnostics: {report_path}")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
