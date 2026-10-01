#!/usr/bin/env python3
"""Opt-in native candidate evaluation; never downloads or changes the plugin."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
PIN = "580e39b69cc1b0ca35c4f8272683e622b2e9b8db"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "build/merman-evaluation/target/release/merman-cli")
    parser.add_argument("--output", type=Path, default=ROOT / "build/merman-evaluation/results")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    records = []

    def run(name, command, expect=0):
        stdout = out / (name + ".stdout")
        stderr = out / (name + ".stderr")
        started = time.perf_counter()
        with stdout.open("wb") as so, stderr.open("wb") as se:
            child = subprocess.Popen([str(binary), *map(str, command)], stdout=so, stderr=se)
            _, status, usage = os.wait4(child.pid, 0)
            child.returncode = os.waitstatus_to_exitcode(status)
        records.append({"name": name, "command": list(map(str, command)), "exit": child.returncode,
                        "elapsed_ms": (time.perf_counter() - started) * 1000,
                        "peak_rss_kib": usage.ru_maxrss})
        if expect == 0:
            assert child.returncode == 0, stderr.read_text()
        else:
            assert child.returncode != 0, name + " unexpectedly succeeded"
            assert stderr.read_text().strip(), name + " lacked diagnostic"
        return stdout.read_text() if stdout.stat().st_size else ""

    run("version", ["--version"])
    capabilities = json.loads(run("capabilities", ["capabilities", "--json"]))
    (out / "capabilities.json").write_text(json.dumps(capabilities, indent=2) + "\n")
    cardinality = {"||": "ONLY_ONE", "o|": "ZERO_OR_ONE", "|o": "ZERO_OR_ONE",
                   "o{": "ZERO_OR_MORE", "}o": "ZERO_OR_MORE", "|{": "ONE_OR_MORE", "}|": "ONE_OR_MORE"}
    for fixture in ("reference", "boundary"):
        source = ROOT / "tests/merman" / (fixture + ".mmd")
        parsed = json.loads(run(fixture + "-parse", ["parse", source, "--pretty"]))
        (out / (fixture + "-model.json")).write_text(json.dumps(parsed, ensure_ascii=False, indent=2) + "\n")
        model = parsed.get("model", parsed)
        expected = []
        for line in source.read_text().splitlines():
            match = re.fullmatch(r'\s*(\w+)\s+([|o}{]{2})(--|\.\.)([|o}{]{2})\s+(\w+)\s*:\s*"(.*)"\s*', line)
            if match:
                a, left, relation, right, b, label = match.groups()
                expected.append((a, b, label, cardinality[right], cardinality[left],
                                 "IDENTIFYING" if relation == "--" else "NON_IDENTIFYING"))
        names = {entity["id"]: name for name, entity in model["entities"].items()}
        actual = [(names[r["entityA"]], names[r["entityB"]], r["roleA"], r["relSpec"]["cardA"],
                   r["relSpec"]["cardB"], r["relSpec"]["relType"]) for r in model["relationships"]]
        assert actual == expected, (fixture, actual, expected)
        if fixture == "reference":
            assert len(actual) == 20
            assert set(model["entities"]) == {v for row in expected for v in row[:2]}
            assert len(model["entities"]) == 14
        else:
            attrs = model["entities"]["person"]["attributes"]
            assert [(a["type"], a["name"], a["keys"], a["comment"]) for a in attrs] == [
                ("int", "id", ["PK"], "identificador"), ("string", "name", [], "José: nombre")]
        for theme in ("default", "dark"):
            for width in (320, 672):
                name = f"{fixture}-{theme}-{width}"
                target = out / (name + ".png")
                run(name, ["render", source, "--format", "png", "--output", target,
                           "--theme", theme, "--raster-fit-width", width,
                           "--background", "#0d1117" if theme == "dark" else "#ffffff",
                           "--raster-max-width", width, "--raster-max-height", 4096,
                           "--raster-max-pixels", width * 4096,
                           "--resource-profile", "interactive", "--operation-timeout-ms", 5000])
                data = target.read_bytes()
                assert data[:8] == b"\x89PNG\r\n\x1a\n"
                w, h = struct.unpack(">II", data[16:24])
                assert 0 < w <= width and 0 < h <= 4096
                records[-1].update(width=w, height=h, sha256=hashlib.sha256(data).hexdigest())
        run(fixture + "-svg", ["render", source, "--output", out / (fixture + ".svg"),
                                 "--svg-pipeline", "resvg-safe", "--operation-timeout-ms", 5000])
    source = ROOT / "tests/merman/reference.mmd"
    for i in range(3):
        run(f"repeat-{i}", ["render", source, "--format", "png", "--output", out / f"repeat-{i}.png",
                            "--raster-fit-width", 672, "--operation-timeout-ms", 5000])
    incomplete = out / "incomplete.mmd"
    incomplete.write_text('erDiagram\nusers ||--o{ buyers : "incompleto\n')
    failed = out / "incomplete.png"
    run("incomplete", ["render", incomplete, "--format", "png", "--output", failed], expect=1)
    assert not failed.exists(), "failed render published an artifact"
    run("source-budget", ["render", source, "--output", out / "budget.svg",
                          "--resource-limit", "max_source_bytes=16"], expect=1)
    assert not (out / "budget.svg").exists()
    capped = out / "capped.png"
    run("raster-cap", ["render", source, "--format", "png", "--output", capped,
                      "--raster-fit-width", 10000, "--raster-max-width", 64,
                      "--raster-max-height", 64, "--raster-max-pixels", 4096])
    assert struct.unpack(">II", capped.read_bytes()[16:24]) == (64, 57)
    deadline = out / "deadline.svg"
    run("deadline", ["render", source, "--output", deadline,
                     "--operation-timeout-ms", 0], expect=1)
    assert not deadline.exists()
    summary = {"pin": PIN, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "fixture_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
               "semantic_checks": "14 entities / 20 exact relationships; boundary cardinalities, roles, types, attributes",
               "timing_scope": "fresh process wall time and per-process wait4 peak RSS; repeats are warm filesystem, not persistent-worker renders",
               "records": records}
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
