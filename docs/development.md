# Development and verification

[Back to README](../README.md) · [Configuration](configuration.md) ·
[Performance and historical evidence](../REPORT.md)

Run the commands below from the repository root. Build the native renderer
explicitly using the [installation instructions](../README.md#installation).
Checks and benchmark launchers do not install dependencies or alter plugin defaults.
Headless checks, inspected rasters, real-terminal observations and user perception
are different kinds of evidence; do not substitute one for another.

## Repository layout

| Path | Purpose |
| --- | --- |
| `lua/mdview/`, `plugin/mdview.lua` | Session controller, palettes and commands. |
| `src/preview.cpp`, `src/mermaid.hpp` | Persistent native Markdown worker and optional diagram subprocess integration. |
| `src/main.cpp`, `scripts/md2png` | Standalone full-document PNG CLI. |
| `styles/markdown.css` | Stock document stylesheet. |
| `scripts/build.sh`, `CMakeLists.txt` | Native build using the litehtml v0.10 Cairo adapter and system libraries. |
| `tests/*.lua`, `tests/smoke.sh` | Regression checks. |
| `tests/bench/`, `scripts/bench-scroll`, `scripts/bench-diagnose` | Frozen benchmark fixture, instrumentation and launchers. |
| `tests/merman/`, `scripts/build-mermaid` | Optional pinned Merman build and evaluation. |

`build/` and `third_party/litehtml/` are generated dependency/build directories,
not plugin source. Ordinary previews have no Python/Node/browser runtime; the
benchmark/evaluation tooling uses Python separately.

## Regression checks

With the existing native build and ImageMagick available:

```bash
./tests/smoke.sh
nvim --headless -u NONE -l tests/plugin.lua
nvim --headless -u NONE -l tests/theme.lua
nvim --headless -u NONE -l tests/cursor.lua
nvim --headless -u NONE -l tests/alerts.lua
```

The optional real-Merman check additionally needs the explicitly built evaluation
binary; it does not download/build Merman automatically:

```bash
nvim --headless -u NONE -l tests/mermaid.lua
```

- `smoke.sh` checks CLI orchestration with a **fake cmark-gfm**, not native pixels.
- `plugin.lua` exercises the native worker/controller with mocked image display
  and cell sizes: plain/attributed PNG parity, tables/lists/entities/code/local
  images, UTF-8/repeated-token positions, actual Neovim wrapped-row scrolling,
  unsaved edits, resize, raw HTML recovery, overlapping events, bounded frames
  beyond Cairo's full-image height limit, the README, close/reopen and cleanup.
  It also checks continuous wheel/arrow input, intermediate publications and final
  convergence, initial placement, fluid overrides and fallback behavior.
- `theme.lua` checks native pixels/geometry, adaptive contrast, highlight fallback,
  custom CSS precedence and coalesced theme/edit/resize reloads.
- `cursor.lua` checks focus, command-line, colorscheme and close restoration,
  including preservation of newer external cursor settings.
- `alerts.lua` checks the five visible titles/borders, false-positive boundaries,
  marker/body anchors, ambiguous parsing and lazy continuation, contrast and
  plain/attributed pixel parity at two widths across three palettes, diagnostic-only
  recoloring, unsaved edits, split/reader scroll/resize, disable and cleanup.
- `mermaid.lua` exercises actual Merman/native rendering, independent image pixel
  comparison, two-diagram navigation, unsaved changes, invalid input/recovery,
  latest revision, cursor-follow, height/width changes, palettes and cancellation.

These checks do **not** prove Kitty composition, physical touchpad smoothness or
support for arbitrary Markdown. Run `tests/plugin.lua` and `tests/smoke.sh` before
committing; run additional checks for affected features.

## Manual Kitty checks

Use **local Kitty outside SSH/tmux**, an already-built worker and your normal
Neovim configuration providing configured image.nvim. These launchers override
probe options for the session without editing your configuration or plugin defaults.
Exit one Neovim before launching another.

### Reader and layers

```bash
bash scripts/manual-base
bash scripts/manual-fluid
bash scripts/manual-layers
# Optional document instead of README:
bash scripts/manual-fluid /absolute/path/to/document.md
```

Base forces raw/smoothing/layers off. Fluid requests raw + factor 0.6 + an 84 px
clamp without layers. Layers requests `FPLOG_RAW_ZBELOW=1` independently of
smoothing. The launchers clear inherited scroll/layer experiment variables.

Try touchpad input, held arrows, `gg`/`G` and `q`. Compare sustained movement and
settling, not a still image. For layers, open the command line, completion menu and
a real LSP hover, then close and verify theme/window highlight restoration. Live
hover requires a configured server; a synthetic float does not substitute for it.

Factor 0.6 was user-preferred and zbelow popup compositing was user-reported working
in their normal configuration. Neither report certifies every terminal/theme or
compositor. Report pauses, incorrect placement, stale overlays or popup visibility
with the active setup options, terminal environment and a reproducible document.

### Themes

```bash
bash scripts/manual-theme dark
bash scripts/manual-theme light
bash scripts/manual-theme nvim
# Optional second argument:
bash scripts/manual-theme nvim /absolute/path/to/document.md
```

Without a document, the temporary fixture includes headings, links, inline/block
code, quotes, tables, a separator and a local image. Source opens left, preview
right. Compare readability and unchanged layout; in nvim mode change colorscheme
while scrolling/editing, resize and close/reopen. Palettes were user-reported
working; this checklist remains useful for another configuration.

This launcher deliberately forces raw, smoothing and zbelow **off**. It isolates
palette presentation and cannot validate popup occlusion through lower layers.

### GitHub alerts

```bash
bash scripts/manual-alerts split dark
bash scripts/manual-alerts replace light
bash scripts/manual-alerts split nvim /absolute/path/to/document.md
```

Arguments are mode, theme and optional document. Without a document, the launcher
copies `examples/alerts.md` into a temporary directory, leaving the tracked fixture
untouched. It enables only alert/palette presentation and explicitly disables
raw, smoothing and zbelow; normal Neovim configuration supplies image.nvim.

Check the five titles, icons, colored borders and body formatting. Edit a marker
and body without saving, scroll through interior lines, resize and close/reopen.
In nvim mode, change colorscheme and check alert readability. Escaped/unknown/code
markers must stay literal. Discard probe edits with `:qall!`.
Native dark/light Octicon PNGs were inspected; actual Kitty acceptance of these
new shapes is pending. Rebuild the native binaries and restart/close the existing
preview worker before checking. The bounded native cost comparison and its limits
are recorded in [REPORT](../REPORT.md#bundled-alert-octicons--2026-10-01) and
`tests/alerts-octicons-observed.json`; it is not a terminal smoothness benchmark.

### Mermaid

Explicitly build the optional renderer first; see
[Mermaid setup](../README.md#mermaid-diagrams-optional).

```bash
bash scripts/manual-merman replace
bash scripts/manual-merman split
# Optional second argument in either mode:
bash scripts/manual-merman split /absolute/path/to/document.md
```

These enable original Mermaid fences, not exported-image substitution. Without a
document they use the original reference and boundary inputs. Split enables
`split_follow="cursor"`; it is still opt-in in normal plugin configuration.

Check automatic rendering, unsaved entity/label changes, syntax error/correction,
resize, scroll and close/reopen. Reader `e` returns to source; reopen with
`:MdViewOpen replace`. In split, edit the source and close with `:MdViewClose`.
Put the cursor on the next diagram's heading without `zt`; fitting active content
should be fully visible and raster position stable while moving within that graph.
Discard probe edits with `:qall!`.

Automatic diagram presentation was user-accepted in both modes with a relationship-
label overlap limitation, and the reader interactive checklist passed. Split
cursor-follow has native/headless and TUI evidence with image display mocked;
its real-Kitty visual acceptance remains pending. See the
[Mermaid report](../MERMAID-RESEARCH.md) for chronology and tested boundaries.

The historical standalone PNG inspection needs generated evaluation artifacts:

```bash
python3 tests/merman/evaluate.py
bash scripts/manual-merman light
bash scripts/manual-merman dark
```

It is separate from automatic-fence validation. The Python evaluator actually
runs the optional CLI and records semantics, raster/resource probes and timings.

## Persistent real-Kitty benchmark

```bash
./scripts/bench-scroll
```

### Prerequisites and isolation

Requires `build/mdview-preview`, Neovim 0.10+ **with Kitty APC TermResponse support
for load ACKs**, Python 3.9+, Kitty, ImageMagick, installed image.nvim and a reachable
local graphical desktop (`DISPLAY` or `WAYLAND_DISPLAY`). The default image plugin
path is `~/.local/share/nvim/lazy/image.nvim`; override with
`MDVIEW_IMAGE_PLUGIN=/path/to/image.nvim`. The ACK requirement is additional to the
plugin's version floor, not a claim that every Neovim 0.10 build supports it.

No dependencies are downloaded, nothing is built, and no normal Neovim
configuration or plugin defaults are changed. SSH/tmux environments are rejected.
A dedicated real Kitty window opens even if the calling terminal is not Kitty;
keep it visible and do not resize/interact during the run. Optional installed
`grim` captures the desktop after initial positioning, outside timed input.

The isolated config uses the real native worker, installed image.nvim helpers,
raw RGBA, factor 0.6 and an 84 px clamp. It copies fixed `tests/bench/fixture.md`,
the frozen fourfold README snapshot used for retained measurements, and starts
in the middle. **Do not regenerate this fixture when editing today's README.**

One sample per scenario:

- 20 wheel mapping callbacks at each of 5/10/30 Hz.
- 400 callbacks at nominal 20 ms, alternating arrows/wheel in four 100-event
  down/up/down/up blocks (200 arrows + 200 wheel).

These are synthetic touchpad-like callbacks, not OS input-queue or physical
input events. Every callback must change the target without reaching a boundary.
A resize, failed ACK, missing dependency or failure to settle aborts rather than
publishing a valid-looking summary.

### Outputs

Each run creates `tests/bench/results/<timestamp>/`. An explicit new directory and
alternative factor are available:

```bash
./scripts/bench-scroll --output tests/bench/results/my-run
./scripts/bench-scroll --factor 0.4 --output tests/bench/results/my-factor04-run
```

Existing output directories are rejected to preserve evidence. Outputs include an
exact fixture copy, `5hz.json`, `10hz.json`, `30hz.json`, `burst.json`, `summary.json`,
runtime/version/fixture-SHA256 metadata and Kitty diagnostics. Raw traces record
input schedules/actual timestamps/targets, DRAW requests, FRAME replies,
transmission/publication times and real Kitty load ACKs. Temporary native/image
files stay inside the result directory. New runtime/results are ignored by
default; selected corrected sample JSON evidence is retained in version control.

### Metric definitions

- **Global intervals:** consecutive Kitty transmission-start times in the input
  phase, excluding initial positioning.
- **Active intervals:** omit a gap if its previous transmitted integer y already
  equals the latest target at that publication. This separates settled idle time
  from movement; it is not an arbitrary gap-length cutoff.
- **p50/p95:** nearest rank, sorted index `ceil(p*n)-1`. **Max:** largest interval.
  **Std:** sample standard deviation (`n-1`), null for fewer than two intervals.
- **Final-target settle:** first transmission at the final target after the last
  input, minus that input's timestamp. **Final-target ACK:** that transmission's
  actual load ACK minus the last input.
- **Raster-request settle:** first post-input DRAW requesting final integer raster
  y, minus last-input time. This is separate from transmission/ACK and from exact
  internal subpixel snap, which may not require another DRAW.
- **DRAW / FRAME / transmission / ACK counts**, plus no-op/boundary counts, separate
  producer rejection, publication, transport response and saturation.

ACKs are requested by benchmark wrappers only. They do **not** measure compositor/
presentation timing or prove zero displayed-frame drops. Compare fixture, viewport,
input cadence and environment alongside any numbers. Historical `/tmp` traces,
exact direction sequence and README snapshot disappeared; the recreated workload
is not a byte-identical historical replay.

The [report](../REPORT.md#persistent-harness-rerun--2026-09-30) retains the corrected
`factor06-readme-20260930` sample, tables and rejected exploratory sample details.
The corrected run did not reproduce historical ~20 ms cadence; that observation
alone does not establish a smoothing regression.

## Controlled revision diagnosis

```bash
./scripts/bench-diagnose --output tests/bench/results/my-diagnosis
```

This is a **historical A/B investigation**, not a benchmark of today's plugin.
It needs local Git refs `d01a8b0` (first committed raw+smoothing controller) and
`bench-harness`; these must already resolve locally. It does not automatically
fetch missing branches. `a26f481` has no Lua controller and is not a runnable arm.

The runner uses isolated checkouts, verifies identical native-source/CSS blobs,
shares the existing compatible Release binary and alternates A/B order. Five
launches per arm cover all four scenarios; the first per arm is discarded. CPUs
0/1/2 must be allowed and on distinct physical cores; Kitty/Neovim/renderer are
pinned respectively. `taskset` and `findmnt` are required. Actual affinity,
governor, load and filesystem are recorded; no governor/default change is made.
Results use medians of per-run p50/p95 and between-run CV
(`100 × sample std / mean`), not a statistical-equivalence confidence interval.

The completed [controlled diagnosis](../REPORT.md#controlled-diagnosis--2026-09-30)
found no evidence of regression between its committed arms. Lost historical
fixtures/traces still prevent causal comparison to earlier faster measurements.
To recompute existing retained data without a new timing run:

```bash
./scripts/bench-diagnose --summarize-only --output tests/bench/results/diagnosis-20260930
```

This updates summaries/comparison in that existing result directory. It requires
those raw artifacts to be present; ignored local files are not promised in a
fresh clone. Native producer-phase results and byte-equivalence evidence remain
in the report rather than being duplicated here.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Renderer missing | Run `./scripts/build.sh` explicitly and check native library/adapter compatibility. |
| image.nvim or pixel-size diagnostic | Configure image.nvim for Kitty and `magick_cli`; run in Kitty with usable cell-pixel geometry. |
| Raw/layers inactive | Check explicit setup overrides and SSH/tmux/Kitty identification; a PNG fallback is not arbitrary-terminal support. |
| Popup drawn behind the raster | Enable zbelow separately from fluid; inspect background/opacity detection warnings. Palette-only probes disable layers. |
| Visible block cursor over preview | Enable Neovim `termguicolors` if desired; it is not forced by the plugin. |
| Raw HTML error | Remove unsupported tags/comments; correction should restore the preview. |
| Mermaid failure | Check executable path, compiled diagram family, syntax/opening source line and resource limits. |
| Split stays on previous graph | Distinguish viewport following from cursor following; use `split_follow="cursor"` for active-content reveal. |

For CLI conversion failures, inspect cmark's exit before blaming Cairo:

```bash
bash -x ./scripts/md2png examples/demo.md /tmp/mdview-demo.png 900
```

The CLI feeds cmark-gfm on stdin because it does not accept `--` as an option
terminator. Temporary HTML is written beside the source to resolve relative local
images, requiring write permission there. Do not use full-document CLI PNGs as
proof that long-document plugin viewports have unbounded raster allocation.
