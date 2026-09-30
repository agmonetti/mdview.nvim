#!/usr/bin/env python3
"""Observation-only native RGBA phase profiling; production sources remain untouched.

Build: python tests/bench/native_profile.py build
Run: python tests/bench/native_profile.py run --runtime tests/bench/results/native-profile/runtime
The runtime must already exist; all durable evidence stays under tests/bench/results.
Use --output <repository-path> before build/run for a new durable artifact root.
Run refuses to overwrite a completed summary; output/runtime must resolve inside the repository.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'tests/bench/results/native-profile'


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError(f'Instrumentation anchor changed: {old!r}')
    return source.replace(old, new, 1)


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'src/preview.cpp').read_text()
    original = source
    replacements = [
        ('                auto surface = cairo_image_surface_create', '                auto phase_setup_begin = Clock::now();\n                auto surface = cairo_image_surface_create'),
        ('                doc->draw(reinterpret_cast', '                auto phase_setup_end = Clock::now();\n                doc->draw(reinterpret_cast'),
        ('                auto draw_status = cairo_status(cr);', '                auto phase_draw_end = Clock::now();\n                auto draw_status = cairo_status(cr);'),
        ('                bool saved = false;', '                bool saved = false;\n                Clock::time_point phase_convert_begin, phase_convert_end, phase_write_end;'),
        ('                    cairo_surface_flush(surface);', '                    phase_convert_begin = Clock::now();\n                    cairo_surface_flush(surface);'),
        ('                    std::ofstream file(out_path, std::ios::binary);', '                    phase_convert_end = Clock::now();\n                    {\n                    std::ofstream file(out_path, std::ios::binary);'),
        ('                    saved = static_cast<bool>(file);', '                    saved = static_cast<bool>(file);\n                    } // Same implicit stream close as production; observed before RGBA destruction.\n                    phase_write_end = Clock::now();'),
        ('                std::cout << "FRAME "', '''                auto phase_total_end = Clock::now();
                auto ms = [](Clock::time_point a, Clock::time_point b) {
                    return std::chrono::duration<double, std::milli>(b-a).count();
                };
                if (out_path.size() >= 5 && out_path.substr(out_path.size()-5) == ".rgba") {
                    std::cerr << "{\\"revision\\":" << rev << ",\\"sequence\\":" << seq
                        << ",\\"top\\":" << top << ",\\"width\\":" << width << ",\\"height\\":" << height
                        << ",\\"setup_ms\\":" << ms(phase_setup_begin, phase_setup_end)
                        << ",\\"doc_draw_ms\\":" << ms(phase_setup_end, phase_draw_end)
                        << ",\\"draw_ms\\":" << ms(phase_setup_begin, phase_draw_end)
                        << ",\\"convert_ms\\":" << ms(phase_convert_begin, phase_convert_end)
                        << ",\\"write_close_ms\\":" << ms(phase_convert_end, phase_write_end)
                        << ",\\"total_ms\\":" << ms(t, phase_total_end) << "}\\n";
                }
                std::cout << "FRAME "'''),
    ]
    for old, new in replacements:
        source = replace_once(source, old, new)
    (OUT / 'preview.instrumented.cpp').write_text(source)
    cmake = (ROOT / 'CMakeLists.txt').read_text().replace('${CMAKE_SOURCE_DIR}', str(ROOT))
    cmake = cmake.replace('src/main.cpp', str(ROOT / 'src/main.cpp'))
    cmake = cmake.replace('src/preview.cpp', str(OUT / 'preview.instrumented.cpp'))
    (OUT / 'CMakeLists.txt').write_text(cmake)
    subprocess.run(['cmake', '-S', str(OUT), '-B', str(OUT / 'build'), '-DCMAKE_BUILD_TYPE=Release'], check=True)
    subprocess.run(['cmake', '--build', str(OUT / 'build'), '--target', 'mdview-preview', '-j2'], check=True)
    (OUT / 'build-metadata.json').write_text(json.dumps({
        'source_sha256': hashlib.sha256(original.encode()).hexdigest(),
        'instrumented_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'build_type': 'Release', 'production_binary_untouched': str(ROOT / 'build/mdview-preview'),
        'phase_definition': {'draw_ms': 'surface setup, background paint, clip calculation and doc->draw',
            'convert_ms': 'surface flush, data/stride access, RGBA vector allocation and straight-alpha conversion',
            'write_close_ms': 'ofstream open/write and implicit close (page-cache completion, no fsync); excludes RGBA destruction',
            'total_ms': 'production DRAW clock to after surface destroy/status check; before JSON/FRAME reporting',
            'residual': 'cairo context destruction, output path decode, RGBA destruction, surface destruction/status check and timestamp overhead'},
    }, indent=2) + '\n')


def command(process, text, response):
    process.stdin.write(text + '\n')
    process.stdin.flush()
    lines = []
    while True:
        line = process.stdout.readline()
        if not line:
            raise RuntimeError('Renderer terminated before response')
        lines.append(line.rstrip())
        if line.startswith('ERROR '):
            raise RuntimeError(line)
        if line.startswith(response + ' '):
            return line.split(), lines


def hexpath(path):
    return str(path).encode().hex()


def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(fraction*len(values))-1)]


def environment(cpu, runtime):
    def capture(args):
        return subprocess.run(args, text=True, capture_output=True).stdout.strip()
    cpudir = Path(f'/sys/devices/system/cpu/cpu{cpu}')
    return {
        'cpu': cpu, 'parent_allowed_affinity': sorted(os.sched_getaffinity(0)),
        'loadavg': Path('/proc/loadavg').read_text().strip(),
        'governor': (cpudir / 'cpufreq/scaling_governor').read_text().strip() if (cpudir / 'cpufreq/scaling_governor').exists() else None,
        'topology': {p: (cpudir / 'topology' / p).read_text().strip() for p in ['core_id', 'physical_package_id', 'thread_siblings_list']},
        'runtime': str(runtime), 'runtime_mount': capture(['findmnt', '-T', str(runtime), '-o', 'TARGET,SOURCE,FSTYPE,OPTIONS', '-n']),
        'repository_mount': capture(['findmnt', '-T', str(ROOT), '-o', 'TARGET,SOURCE,FSTYPE,OPTIONS', '-n']),
    }


def run(args):
    runtime = Path(args.runtime).resolve()
    if not runtime.is_dir():
        raise RuntimeError('Runtime directory must already exist')
    if args.cpu not in os.sched_getaffinity(0):
        raise RuntimeError(f'CPU {args.cpu} unavailable; explicit CPU change required')
    OUT.mkdir(parents=True, exist_ok=True)
    css = OUT / 'markdown.snapshot.css'
    css.write_bytes((ROOT / 'styles/markdown.css').read_bytes())
    metadata = {'before': environment(args.cpu, runtime), 'viewport': [948, 1012],
        'repetitions': args.repetitions, 'discarded_runs': [0],
        'offset_policy': '11 equally spaced percent positions of max(0, document_height-1012), nearest integer y; repeated 3 cycles in identical order',
        'frames_per_run': 33, 'fixtures': {},
        'quantiles': 'nearest rank: sorted[max(0, ceil(p*n)-1)]'}
    metadata['measurement_scope'] = 'Native phases only; excludes launcher, Neovim, terminal transfer, Kitty paint; JSON total authoritative (FRAME elapsed includes JSON reporting).'
    metadata['write_semantics'] = 'ofstream open/write/implicit close, page-cache completion only; no fsync.'
    summary = {}
    for fixture in ['tests/bench/fixture.md', 'examples/demo.md']:
        path = ROOT / fixture
        name = path.stem
        snapshot = OUT / f'{name}.snapshot.md'
        snapshot.write_bytes(path.read_bytes())
        runs = []
        for repetition in range(args.repetitions):
            raw_path = OUT / f'{name}-run{repetition}-phases.jsonl'
            with raw_path.open('w') as phases:
                p = subprocess.Popen(['taskset', '-c', str(args.cpu), str(OUT / 'build/mdview-preview')],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=phases, text=True)
                try:
                    # taskset applies affinity before the first LOAD response.
                    ready, load_lines = command(p, f'LOAD 1 948 {hexpath(snapshot)} {hexpath(path.parent)} {hexpath(css)}', 'READY')
                    actual_affinity = sorted(os.sched_getaffinity(p.pid))
                    doc_height = float(ready[3])
                    offsets = [round(max(0, doc_height-1012)*i/10) for i in range(11)]
                    frame_lines = []
                    for seq, offset in enumerate(offsets*3, 1):
                        frame, lines = command(p, f'DRAW 1 {seq} 0 {offset} 0 1012 {hexpath(runtime / "native-frame.rgba")}', 'FRAME')
                        frame_lines.extend(lines)
                    p.stdin.write('QUIT\n'); p.stdin.flush(); p.stdin.close()
                    p.wait(timeout=30)
                    if p.returncode:
                        raise RuntimeError(f'Renderer exit {p.returncode}')
                finally:
                    if p.poll() is None:
                        p.kill(); p.wait()
            rows = [json.loads(line) for line in raw_path.read_text().splitlines()]
            if len(rows) != 33:
                raise RuntimeError(f'Expected 33 records, got {len(rows)}')
            (OUT / f'{name}-run{repetition}-protocol.log').write_text('\n'.join(load_lines+frame_lines)+'\n')
            run_record = {'run': repetition, 'discarded': repetition == 0, 'load_ms': float(ready[4]),
                'document_height': doc_height, 'offsets_y': offsets, 'affinity': actual_affinity,
                'environment_after': environment(args.cpu, runtime), 'statistics': {}}
            for field in ['setup_ms', 'doc_draw_ms', 'draw_ms', 'convert_ms', 'write_close_ms', 'total_ms']:
                values = [row[field] for row in rows]
                run_record['statistics'][field] = {'p50': percentile(values, .5), 'p95': percentile(values, .95)}
            runs.append(run_record)
        metadata['fixtures'][fixture] = {'sha256': hashlib.sha256(snapshot.read_bytes()).hexdigest(),
            'snapshot': str(snapshot), 'css_sha256': hashlib.sha256(css.read_bytes()).hexdigest(), 'runs': runs}
        summary[fixture] = {}
        for field in runs[0]['statistics']:
            summary[fixture][field] = {}
            for stat in ['p50', 'p95']:
                values = [r['statistics'][field][stat] for r in runs[1:]]
                mean = statistics.mean(values)
                summary[fixture][field][stat] = {'median_ms': statistics.median(values),
                    'cv_sample_stdev_over_mean': statistics.stdev(values)/mean if mean else None,
                    'retained_run_values_ms': values}
    metadata['after'] = environment(args.cpu, runtime)
    (OUT / 'run-metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    frame = runtime / 'native-frame.rgba'
    if frame.exists():
        frame.unlink()
    print(json.dumps(summary, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    global OUT
    parser.add_argument('--output', type=Path, default=OUT,
        help='Durable artifact root inside this repository (set before build/run)')
    sub = parser.add_subparsers(dest='mode', required=True)
    sub.add_parser('build')
    runner = sub.add_parser('run')
    runner.add_argument('--runtime', required=True)
    runner.add_argument('--cpu', type=int, default=2)
    runner.add_argument('--repetitions', type=int, default=5)
    args = parser.parse_args()
    OUT = args.output.resolve()
    if not OUT.is_relative_to(ROOT):
        parser.error('--output must resolve inside the repository')
    if args.mode == 'run':
        if not Path(args.runtime).resolve().is_relative_to(ROOT):
            parser.error('--runtime must resolve inside the repository')
        if (OUT / 'summary.json').exists():
            parser.error('summary.json already exists; choose a new --output to preserve measured evidence')
    if args.mode == 'build':
        build()
    else:
        if args.repetitions < 5:
            parser.error('At least five repetitions required')
        run(args)


if __name__ == '__main__':
    main()
