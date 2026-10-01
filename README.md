# mdview.nvim — experimental native Markdown preview

A proportional Markdown preview in a Neovim split using Kitty and `image.nvim`, with a persistent native renderer. The plugin now lives in this repository; real-document Kitty acceptance is still pending. No browser, Node.js, or Python runtime is used. Local-only agent notes may be present in the git-ignored `AGENTS.md`; they are not distributed with clones.

**Pipeline:** `cmark-gfm → HTML + local CSS → litehtml v0.10 + Cairo/Pango → PNG (default) / RGBA (opt-in) → Kitty`.

## Install and use the plugin

Requires Neovim 0.10+, Kitty, configured [image.nvim](https://github.com/3rd/image.nvim) with its Kitty backend and `magick_cli` processor, ImageMagick, and the native packages listed below. Build explicitly with `./scripts/build.sh`; opening the plugin never downloads or compiles anything.

For lazy.nvim, add a local spec (replace the path):

```lua
return {
  {
    dir = "/path/to/mdview-nvim-lite",
    name = "mdview-nvim-lite",
    cmd = { "MdView", "MdViewOpen", "MdViewClose" },
    dependencies = { "3rd/image.nvim" },
    build = false,
  },
}
```

Inside Kitty, open any Markdown file with your normal Neovim configuration and run `:MdView`. It toggles the preview using the configured mode (default: **reader mode**, `replace`). Because `MdView` is the shortest command, it appears first when completing `:MdV<Tab>`.

Use `:MdViewOpen [replace|split]` when you want to explicitly choose a mode and `:MdViewClose` to close the preview. `:MdView` is the one-command toggle: it opens when closed and closes when open, so it is convenient for repeated use and key mappings; it does not replace the explicit commands.

In reader mode:
- **Scroll:** `j` / `k` (step), `d` / `u` (half page), `<Space>` / `<C-f>` / `PageDown` (full page), `<S-Space>` / `<C-b>` / `PageUp`, `gg` (top), `G` (bottom), or mouse wheel.
- **Navigate:** `]]` (next heading), `[[` (previous heading), `t` (table of contents picker via `vim.ui.select`).
- **Search:** `/` (search forward in text), `?` (backward), `n` / `N` (next/prev match).
- **Edit:** `i` / `a` (enter insert mode at current reading line), `o` (open line below), `e` / `<CR>` (normal mode at current line).
- **Close:** `q` or `<Esc>` returns to your editor buffer at the exact line where you were reading.

The document window hides the normal/visual cursor using Neovim's transparent
cursor highlight (`termguicolors` required in the TUI). Command-line input,
focused floats, source windows and closing/editing restore the original cursor
configuration. The plugin does not enable `termguicolors` or change global Cursor colors.

To open in side-by-side split mode instead:

```vim
:MdViewOpen split
:MdView split
```

By default, split mode follows the first visible source line and clips at the last
visible source block (`w0` to `w$`). If you mainly use side-by-side mode and want
the preview to follow the content you are actively working on, cursor-follow is a
good option. Keep the default `"viewport"` when you prefer the preview to track the
first visible source line.

```lua
require("mdview").setup({ split_follow = "cursor" }) -- useful for cursor-oriented split use; default: "viewport"
```

Cursor follow moves the preview only enough to reveal the active rendered text
row or the entire Mermaid diagram when it fits; moving within already visible
content keeps the raster position. A heading immediately followed by a Mermaid
fence includes that diagram in the reveal. If heading and diagram cannot fit
together, the diagram takes priority; a diagram taller than the panel shows its
start without invented relation-level positions. This mode does not clip at the
source window's bottom line, center the cursor, or change the source viewport.
It reacts to normal/insert cursor movement, reuses prepared diagrams on scrolling,
and recalculates visibility after layout/viewport changes. Reader mode is unaffected.

The preview reads unsaved buffer snapshots, never writes the source, resolves local images relative to the source file, coalesces edits/width changes, and draws only pane-height PNGs. Height changes recrop without relayout. Smooth scrolling uses source-byte ranges on rendered text leaves. One preview session is supported at a time. Switching the source window to another buffer closes the session.

Optional configuration:

```lua
require("mdview").setup({
  mode = "replace",                     -- "replace" (default reader mode) or "split" (side-by-side)
  renderer = "/path/to/mdview-preview", -- defaults to this checkout's build/
  stylesheet = "/path/to/markdown.css", -- defaults to styles/markdown.css
})
```

### Document color themes (opt-in)

```lua
require("mdview").setup({ theme = "dark" }) -- "dark" | "light" | "nvim"
-- Independent options can be combined:
require("mdview").setup({ preset = "fluid", theme = "nvim" })
```

Omitting `theme` preserves the existing stylesheet unchanged, including custom
`stylesheet` colors. Explicit `dark` reproduces the stock colors; `light` supplies
an opaque reading palette. Explicit themes append color-only overrides after the
configured stylesheet: fonts, sizes, spacing and border widths remain its responsibility.
Fluid and layers remain independent; themes do not enable either.

`nvim` translates effective, linked global highlights into a document palette:
`Normal` background/text, `Title` headings, `Underlined` (then `Identifier`) links,
`Comment` secondary/quote text, and `NormalFloat` code/table-header surfaces.
Missing colors use the built-in palette selected by `background`; a missing or
transparent `Normal.bg` never assumes black. Equal surfaces and decorative borders
are derived by blending background/text. Relative sRGB luminance checks enforce
at least 4.5:1 for adaptive text/quotes/code against their backgrounds, using
readable fallback colors when necessary. Highlight bold/italic attributes are
not copied; code syntax highlighting and document transparency are not included.

Adaptive colors resolve on open, `ColorScheme`, and `OptionSet background`.
Only a changed palette triggers a coalesced reload through the existing revision
pipeline, preserving the reading target and rejecting outdated frames. There is
no highlight lookup or CSS write per scroll frame. Direct highlight changes without
those events require closing/reopening. Effective CSS lives in the session directory
and is removed with the session. Theme changes incur a one-time full relayout.

Inside local Kitty, with the usual image.nvim configuration:

```bash
bash scripts/manual-theme dark
bash scripts/manual-theme light
bash scripts/manual-theme nvim
# Optional second argument: your own Markdown document.
```

The default temporary fixture includes headings, links, inline/block code, quotes,
tables, a separator and a local image; source opens left and preview right.
Compare readability and unchanged layout. In `nvim`, change your colorscheme while
scrolling/editing, resize, then close/reopen. Real Kitty visual acceptance remains
pending; headless checks cannot substitute for it.

Raw HTML currently produces an explicit preview error; removing it recovers without restarting Neovim. Remote images are not fetched. Math rendering, syntax highlighting, interactive links/text selection, and exact alignment with conceal/virtual source text are not supported or validated. Source columns for transformed Markdown are mapped through cmark literals; unsupported attribution fails explicitly rather than publishing a guessed mapping. Whole-document layout memory and edit/width-change cost still grow with document size; only raster allocation is bounded.

### Experimental Mermaid fences (opt-in)

The isolated, evaluated Merman CLI can render original `mermaid` fences automatically:

```lua
require("mdview").setup({
  mermaid = { renderer = "/absolute/path/to/build/merman-evaluation/target/release/merman-cli" },
})
-- Disable again explicitly: require("mdview").setup({mermaid=false})
```

Omitted/false keeps existing literal code rendering. Opening never downloads,
builds or installs Merman. This is an experimental Linux CLI integration, not a
permanent dependency or complete Mermaid compatibility promise. The evaluated
binary supports ER diagrams; other diagram families need a compatible build.
See [MERMAID-RESEARCH.md](MERMAID-RESEARCH.md) for the pinned version and evaluation.

The cmark AST detects fenced blocks whose first info word is exactly `mermaid`.
Their unchanged content is rendered during **LOAD**, then composed as session-owned
local PNGs. No exported image links or source changes are required. Unsaved edits,
width changes and explicit document-theme changes regenerate diagrams; scroll and
height-only resize reuse prepared layout. Rapid edits coalesce through the existing
revision pipeline; obsolete frames are not displayed. Failures clear the old
preview, identify the block's opening line and recover after correction. Closing
stops pending subprocesses and removes generated files.

Source navigation associates **every line of a diagram with the whole block**,
not a rendered entity or relation. Diagram background follows explicit
`theme="dark"|"light"|"nvim"`; luminance selects Merman dark/default colors, not
an exact copy of every document color. Without an explicit theme, diagrams use
stock dark background `#0d1117`, including with custom stylesheets.

Resource limits: 1 MiB source per fence, 16 diagrams and 16 Mi pixels retained per
LOAD. Each PNG is at most `viewport_width - 64` pixels wide (minimum 1), 4096 tall
and 4 Mi pixels; the header is checked before decoding. The isolated process has
a **768 MiB address-space cap** covering intermediate allocations, 6 CPU seconds,
24 MiB output-file cap and 6-second wall deadline; Mermaid preparation has a
15-second LOAD budget. These caps can reject large graphs; they are not evidence
of low peak memory, a sandbox for arbitrary executables, or bounded Markdown layout.

Inside local Kitty, with the normal Neovim/image.nvim configuration:

```bash
bash scripts/manual-merman replace /absolute/path/to/document.md
bash scripts/manual-merman split /absolute/path/to/document.md
# Without a document argument, use the original reference and boundary fences.
```

Exit one Neovim before opening the other. Check initial automatic rendering, change
an entity/label without saving, introduce and correct a syntax error, scroll,
resize, close/reopen, and discard probe edits with `:qall!`. Reader: `e` enters
the source; `:MdViewOpen replace` returns to the preview; `q` closes. Split:
edit/scroll the source and close with `:MdViewClose`. The user reports automatic
diagram presentation looks good in reader and split, except overlapping relationship
labels above `discounts`; the supplied web-app reference also shows overlap there.
The subsequent interactive checklist passed in reader mode; split passed except
delayed scroll-follow near the next diagram. A reproduced concealed-line case kept
the previous diagram's hidden closing fence as Neovim's logical topline. Split now
anchors the first displayed source line instead; regression and real-TUI dispatch
checks passed with image display mocked. The user reported improvement, then
clarified that the preview should follow the cursor rather than wait for the
source topline to reach the second section. The opt-in `split_follow="cursor"`
implements minimal reveal scrolling; `scripts/manual-merman split` enables it.
Native pixel/resize/rapid-cursor regressions and natural TUI cursor events passed
with image display mocked; Kitty visual acceptance of cursor follow is pending.

### Opt-in fluid preset

The user manually preferred `smooth06` in real Kitty; **0.6 is the reference, not a new default**. Enable the recommended combination with one setup option:

```lua
require("mdview").setup({ preset = "fluid" })
-- Equivalent explicit setup (choose one):
require("mdview").setup({ raw = true, smooth = true, factor = 0.6, clamp = 84 })
```

`clamp` is pixels. Explicit setup fields override preset values and matching environment controls. `raw=false` and `smooth=false` force those features off. Changes apply on the next preview opening. Fluid does **not** enable the layer experiment. Without a preset or other opt-in, defaults remain unchanged; making raw + smooth default remains the user's decision after extended real use.

Raw requires **local Kitty**, its graphics protocol and access to Neovim's temporary files. SSH (`SSH_CLIENT` / `SSH_TTY` / `SSH_CONNECTION`), tmux (`TMUX`) and lack of Kitty identification automatically use the PNG/image.nvim path. Requested smoothing remains active, but PNG fallback does not inherit the raw performance measurements. This is environment-based detection, not complete graphics-capability negotiation; PNG still needs a working configured image backend. Missing dependencies or cell-pixel dimensions produce an explicit diagnostic, not an installation/download or a fake successful preview. See [REPORT.md](REPORT.md) for fallback boundaries.

### Opt-in reader experiments

Keep transport fixed when comparing scroll variants. `FPLOG_RAW=1` enables the same raw opt-in independently of the preset.

- `FPLOG_SMOOTH=1`: timer-paced exponential reader scrolling (16 ms), one frame in flight, exact snap below 1 px. Tune with `FPLOG_SMOOTH_FACTOR` (reference `0.6`; legacy implicit `0.4` unchanged), `FPLOG_SMOOTH_INTERVAL` (16–20 ms), and `FPLOG_CLAMP_PX` (reference `84`; otherwise four terminal rows). `FPLOG_CLAMP` remains row-based tuning. Smaller factors can produce a noticeable settling tail; this is not a latency guarantee.
- `FPLOG_P3=1`: standalone per-frame clamp comparison.
- `FPLOG_STEP=1`: one-row wheel step; `FPLOG_STEP=2`: two-row reference.
- `FPLOG_C=1`: combined two-row wheel step plus four-row per-frame clamp, behind one experiment switch.
- `setup({zbelow=true})` or `FPLOG_RAW_ZBELOW=1`: enables local raw transport and places the image below non-default cell backgrounds **only after detecting** the terminal background through OSC 11 and opacity through Kitty XTGETTCAP. Explicit `zbelow=false` overrides the environment; omitted remains inactive unless the flag is set. Fluid does not enable it. A viewer-only highlight namespace matches that background. Missing/invalid responses automatically retain `z=-1` with a warning; no fixed-black fallback. ColorScheme, focus and terminal theme notifications trigger redetection; a one-second poll also checks background/opacity changes. Closing restores the prior window namespace. No float event hides the document.

Example, from this checkout inside Kitty:

```bash
FPLOG_RAW=1 FPLOG_SMOOTH=1 FPLOG_SMOOTH_FACTOR=0.6 FPLOG_CLAMP_PX=84 nvim '+MdViewOpen replace' README.md
# Separate layer experiment, without smoothing:
FPLOG_RAW_ZBELOW=1 nvim '+MdViewOpen replace' README.md
```

**Layers await the user's manual acceptance; their implementation was not changed by the fluid-preset task.** The lower-layer experiment was checked with Rose Pine and Kitty `background_opacity=0.65`: the inspected document-region screenshot matched the regular layer pixel-for-pixel; opaque cmdline/completion/hover UI covered it. Hover used synthetic content through the actual Neovim floating-preview API, not a live server response. Terminal-theme updates and close restoration were observed. This is narrow real-terminal evidence, not acceptance of arbitrary terminal/theme combinations. The renderer's opaque document background comes from CSS, not Rose Pine; the layer switch does not retheme the document.

### Measured cadence and alternatives not selected

Existing raw `smooth06` traces, interval between Kitty transmission starts (ms), **not screen presentation**:

| Scenario | p50 | p95 | Max | Std |
| --- | ---: | ---: | ---: | ---: |
| 5 Hz | 20.41 | 115.68 | 133.96 | 30.22 |
| 10 Hz | 18.86 | 21.34 | 32.59 | 1.92 |
| 30 Hz | 18.44 | 20.10 | 20.60 | 0.77 |
| Burst | 18.85 | 33.14 | 122.01 | 14.80 |

The 5 Hz/burst maxima include deliberate idle gaps after settling. Excluding those, active p95/max is **24.43/32.56**, **21.34/32.59**, **20.10/20.60**, **22.78/44.54 ms** respectively. Every issued DRAW was published and received an OK transmission ACK in these four traces; that does not certify zero compositor/presentation drops. Timer/producer phase is a plausible explanation for occasional extra waits, not an independently proven cause. One run per scenario, reused data: no new benchmark sweep. Full interval/std tables and trace decomposition: [REPORT.md](REPORT.md).

| Historical alternative | Evidence for not selecting it as the reference |
| --- | --- |
| F1 (`FPLOG_F1_CAIRO`) | Native p95 **80.90 ms** vs PNG baseline **43.74 ms**; direct Cairo PNG encoding remained costly. |
| F3 (`FPLOG_F3_SHM`) | Native p95 gain over F2 **0.43 ms** at 957×1008 / **1.03 ms** at 1500×1000, below baseline IQR **2.58 ms**; retained simpler tmpfs-file transport. |
| PNG0 (`FPLOG_C_PNG0`) | **Not tested, not rejected:** saved C/base PNGs were byte-identical, so actual compression0 was not established. Production fixes `"compression", "1"`; GdkPixbuf supports levels 0–9. Those timings do not rank PNG0. |
| P2 (`FPLOG_P2`) | Still quantized; historical displacement p95 **220.5 px**, input→ACK p95 **49.47 vs base 46.65 ms**. Saturation confounds that old comparison; no conclusive ranking claimed. |
| Factor 0.25 | Final-position settling **344/381/414 ms** at 5/10/30 Hz, **423 ms** burst: over ~150 ms. |
| Factor 0.4 | **200/194/222 ms**, **207 ms** burst: longer tail than 0.6. User still liked its perception; not removed or visually rejected. |

Historical F1/F3/PNG0/P2 flags belonged to isolated benchmark copies and are **not runtime toggles in the installed plugin**. They are distinct from the available scroll treatment `FPLOG_C=1`. Both smaller factors remain valid tuning values. Measurements from different fixtures/studies are not one comparable latency dataset; methodology and sources are in [REPORT.md](REPORT.md).

### Reproducible checks

```bash
./tests/smoke.sh                            # original CLI orchestration, mocked cmark
nvim --headless -u NONE -l tests/plugin.lua  # native renderer + Lua controller; mocked image display
nvim --headless -u NONE -l tests/theme.lua   # palette contrast, native geometry/pixels, live theme reload
nvim --headless -u NONE -l tests/cursor.lua  # viewer focus and cursor restoration transitions
nvim --headless -u NONE -l tests/mermaid.lua # opt-in fences; requires evaluated isolated Merman binary
```

The plugin regression check also exercises continuous reader wheel/arrow input, intermediate frame publication, final scroll convergence, and initial placement (mocked image display). It covers PNG pixel parity between plain and attributed HTML (including tables, nested lists, entities, code indentation, and a relative local image), actual Neovim soft-wrap scroll with UTF-8 and repeated text, unsaved edits, resize, error recovery, overlapping events, a document exceeding Cairo's full-image height limit, this repository's README, close/reopen, and worker/temp-file cleanup. It does **not** establish Kitty visual acceptance or support for arbitrary Markdown.

### Persistent real-Kitty benchmark

From this checkout, run:

```bash
./scripts/bench-scroll
```

Prerequisites: the already-built `build/mdview-preview`, Neovim 0.10+ (with Kitty APC `TermResponse` support for load ACKs), Python 3.9+, Kitty, ImageMagick, an installed `image.nvim` checkout, and a reachable local graphical desktop (`DISPLAY` or `WAYLAND_DISPLAY`). The default image plugin path is `~/.local/share/nvim/lazy/image.nvim`; override it with `MDVIEW_IMAGE_PLUGIN=/path/to/image.nvim`. No dependencies are downloaded, nothing is built, and no normal Neovim configuration or plugin defaults are changed. SSH/tmux environments are rejected. A dedicated real Kitty window is launched even when the calling terminal is not Kitty; keep it visible and do not resize or interact with it during the run. Optional installed `grim` captures the actual desktop after initial positioning, outside the timed input phase.

The isolated config uses the real native worker, installed image.nvim helpers, raw RGBA, factor **0.6**, and an **84 px** clamp. Its fixed `tests/bench/fixture.md` is the frozen fourfold README snapshot used for the retained measurement; each output gets an exact copy and starts in the middle. One sample per scenario: **20 wheel mapping callbacks at 5/10/30 Hz**, then **400 callbacks at nominal 20 ms**, alternating arrows/wheel in four 100-event down/up/down/up blocks (200 arrows + 200 wheel). These are synthetic touchpad-like callbacks, not OS input-queue or physical touchpad events. Every callback must change the target without reaching a boundary; a resize, failed ACK, missing dependency, or failure to settle aborts clearly rather than publishing a valid-looking summary.

All outputs stay under `tests/bench/results/<timestamp>/`: `fixture.md`, raw `5hz.json`, `10hz.json`, `30hz.json`, `burst.json`, `summary.json`, runtime/version/fixture-SHA256 metadata, and Kitty diagnostics. `--output tests/bench/results/my-run` chooses a new directory; `--factor 0.4` is an explicit alternative, not a changed default. Raw traces include input schedules/actual timestamps/targets, native DRAW requests and FRAME replies, transmission starts/publication timestamps, and actual Kitty load ACKs. Temporary native/image files also stay inside the result directory. New results/runtime files are ignored by default; the corrected sample's JSON evidence is retained in version control.

Metric definitions match the historical interval analysis:

- **Global intervals:** consecutive Kitty transmission-start timestamps in the input phase, excluding initial positioning.
- **Active intervals:** exclude a gap when its previous transmitted integer y already equals the latest requested target at that publication. This distinguishes intentional idle periods from ongoing movement; it is not a guessed gap-length cutoff.
- **p50/p95:** nearest rank, sorted index `ceil(p*n)-1`. **Max:** largest interval. **Std:** sample standard deviation (`n-1`), undefined/null for fewer than two intervals.
- **Final-target settle:** first transmission at the final target after the last input, minus that input's timestamp. **Final-target ACK:** that transmission's actual load ACK minus the last input.
- **DRAW / FRAME / transmission / ACK counts** and no-op/boundary counts distinguish producer rejection, publication, transport response, and saturation. Load ACKs are requested only by benchmark wrappers; they do **not** prove compositor/presentation timing or zero displayed-frame drops.
- **Raster-request settle (diagnosis):** first DRAW requesting the final integer raster y after the last input, minus that input's timestamp. Logged separately from transmission/ACK; reaching that integer y can precede the controller's exact subpixel snap, which need not issue another DRAW.

Historical comparison is not byte-identical: the old `/tmp` traces, exact 400-event direction sequence, and historical README snapshot disappeared; actual window/cell dimensions are recorded rather than assumed. Compare fixture/viewport/input cadence alongside the numbers. The retained `factor06-readme-20260930` sample is the corrected fourfold-README run, at **948×1012**, with zero no-op/boundary inputs and successful ACKs for all transmissions. Its active p95 is **60.80/48.97/47.11/51.83 ms** and settling **259/315/454/1233 ms** at 5/10/30 Hz/burst: these do **not** reproduce the faster historical cadence. Native median draw times themselves are **32.14/35.02/35.85/38.13 ms**; fixture/environment differences prevent attributing a regression to smoothing. Full new/historical tables: [REPORT.md](REPORT.md).

The earlier heavy `factor06-20260930` exploratory sample remains locally but is explicitly rejected in its `validity.json`: the user observed stale source text overlaid on the raster, and its 240-chapter fixture was not comparable. The harness now explicitly redraws buffer transitions; the corrected real desktop screenshot was inspected without that overlay and is retained locally, not committed. This narrow surface check is not the user's manual smoothness/layer acceptance.

Controlled historical/current comparison, five runs per scenario with the first discarded:

```bash
./scripts/bench-diagnose --output tests/bench/results/my-diagnosis
```

This diagnosis runner compares the first committed raw+smoothing controller (`d01a8b0`; `a26f481` contains no Lua controller) against `bench-harness`, using isolated checkouts inside the result directory. It requires allowed CPUs 0/1/2 on distinct physical cores and pins Kitty/Neovim/renderer respectively; no governor or defaults are changed. It verifies identical native-source/CSS blobs before sharing a Release binary, alternates A/B order, records actual affinity/governor/load/filesystem, and reports medians of per-run p50/p95 plus between-run CV (`100 × sample std / mean`). New and historical factor0.6 values remain causally non-comparable until diagnosis; historical traces/fixture were not retained. See [REPORT.md](REPORT.md) for results and limitations.

### Manual Kitty checks

Run these **inside local Kitty**, with your normal Neovim configuration providing image.nvim; an optional document path replaces README:

```bash
bash scripts/manual-base [document.md]
bash scripts/manual-fluid [document.md]
bash scripts/manual-layers [document.md]
```

Omit the bracketed argument to use README. Base forces raw/smoothing/layers off; fluid opts into raw + factor0.6 + clamp84 without layers; layers sets `FPLOG_RAW_ZBELOW=1` independently of smoothing. These scripts do not modify your configuration or global defaults.

In each reader, try your touchpad, hold the arrow keys, use `gg`, and press `q` to close. Compare sustained movement and settling, not just a still image. For layers, check your command line, completion menu, and a real LSP hover (requires your configured server), then close and verify theme/window highlight restoration. Missing LSP hover is an unexercised prerequisite, not a substitute synthetic acceptance. Report perceived pauses, incorrect placement, stale overlays, or layer visibility; automated callback/ACK measurements do not replace your manual visual acceptance.

## Earlier prototype evidence

- **Stage 1 validated:** rendered `examples/demo.md` to PNG and viewed it in Kitty.
- **Stage 2 demonstrated:** a temporary `image.nvim` setup displayed that PNG in a Neovim split. This is a manual experiment, not an implementation or committed dependency.
- **Temporary scroll-follow demonstrated in Kitty:** the user confirmed that the latest `/tmp/mdview-xml-run.sh` split updates the right preview when scrolling the Markdown, as did earlier probes. This experiment uses a synthetic fixture, source-line anchors, and crops of a cached full-document PNG; its code is not in this repository. The latest screenshot also confirms readable table borders and a preview sized to the pane.
- **Temporary unsaved-buffer probe visually accepted in Kitty:** the user reported that `/tmp/mdview-edit-run.sh` passed after editing and scrolling. It rebuilds the image and source-line anchors from the unsaved Neovim buffer; a headless run also confirmed the PNG and anchors changed while the Markdown file on disk stayed unchanged. This validates the synthetic fixture only, not arbitrary Markdown, long documents, or a repository plugin.
- **Temporary split-resize probe reported working in Kitty:** `/tmp/mdview-resize-run.sh` rebuilds the full PNG and source-line anchors at the new preview width, and recrops to the pane height. A headless Neovim test exercised resizing, scrolling, an unsaved edit, height-only resizing, and rapid width changes. The user reported that the Kitty probe seemed to work; a screenshot shows the edited heading in both the modified source and the preview. The single screenshot does not independently prove before/after resize behavior or exact alignment. Full-document rasterization remains unbounded.
- **Temporary bounded-viewport split visually accepted for recovery after an unsaved edit:** after the corrected `/tmp/mdview-bounded-run.sh` probe, the user reported that the Kitty test worked perfectly. The probe lays out an 80-chapter synthetic Markdown document once per edit/width change and renders pane-height viewports instead of a full-document PNG. The report follows the specific instruction to insert a heading with real keystrokes and check that the right pane reappears; it does not independently establish exact alignment at chapter 80, resize behavior, or support for arbitrary Markdown. A separate headless burst on 120 synthetic mixed chapters (3,960 source lines) coalesced 30 scroll, 5 edit, and 5 width-change events into three layouts and four frames; its final frame was inspected, but this is not a Kitty visual or real-world workload validation. All integration code remains under `/tmp`.
- **Concurrent headless stress (temporary prototype):** a varied 240-chapter fixture (1,909 source lines) survived eight edits, width changes, and scroll requests injected while revision 2 was laying out. The last viewport used the newest buffer position and width; the disk file remained unchanged. Three layouts and three frames were logged, with a clean worker exit. A separate single-run size sweep of varied 120/240/480-chapter fixtures measured XML/HTML attribution at 49/108/202 ms and native layout at 317/605/1,291 ms (552 px width); native renderer peak RSS was 73/122/220 MiB. The 480-chapter bounded frame showed the last heading. These are synthetic, headless, warm-machine observations, not Kitty visual acceptance, sustained-load performance, or arbitrary-Markdown support.
- **Quantitative physical alignment and soft-wrap measurement:** on a 120-chapter varied fixture (953 lines, 52,646 px height at 552 px), all 528 attributed text lines matched actual Cairo/Pango draw coordinates within 0.5 px. Soft-wrap analysis showed that when Neovim uses `smoothscroll = true`, line-only anchors stay on row 0, producing up to 324.8 px desync (average 61.9–85.5 px) as `skipcol` increases; character-proportional interpolation still errs by up to 301.4 px, while the leaf-matching experiment reported 0.0 px against its own matching result (not an independent accuracy check). With `smoothscroll = false`, scrolling is by physical lines only (`skipcol = 0`). Raw HTML inline/block tags and comments fail explicitly (`raw HTML is not instrumented`) with clean preview error display and immediate recovery upon removal.
- **Sustained overlapping stress probe:** a 5-wave headless test (6 rapid overlapping edits/resizes during in-flight layout, raw HTML error injection and recovery, 4 post-recovery edits, and a line-850 scroll) converged in 2.2 s total across 3 layouts and 4 frames. The final frame was non-blank, disk files were untouched, and 0 hanging persistent processes remained.

## Build on Arch Linux

```bash
sudo pacman -S --needed base-devel cmake git pkgconf cmark-gfm litehtml cairo pango gtk3
./scripts/build.sh
```

The system `litehtml` package provides the library, not its Cairo renderer. `scripts/build.sh` downloads the litehtml **v0.10** source into the ignored `third_party/litehtml/` directory to compile that adapter, then links against the system library. The adapter and library versions must remain compatible. No browser or Node.js is used.

## Render and view the fixture

```bash
./scripts/md2png examples/demo.md /tmp/mdview-demo.png 900
kitten icat /tmp/mdview-demo.png
```

Run `kitten icat` inside Kitty. To inspect only Markdown-to-HTML conversion:

```bash
./scripts/md2png --html-only examples/demo.md /tmp/mdview-demo.html
```

Temporary HTML is created beside the Markdown file so relative local image paths can resolve, then removed. The output is a **full-document image**; its dimensions and performance have not been validated for long documents.

## Current limitations

- A rendered PNG has no text selection or interactive links.
- litehtml is a layout engine, not a browser; its CSS support is partial. The current stylesheet is an initial dark theme, not a verified VS Code match.
- Code blocks are not syntax-highlighted.
- Local image formats depend on GdkPixbuf support; remote images have not been validated.
- Full-document rasterization in the repository CLI may consume excessive memory for long files. The temporary bounded-viewport probe avoids full-document PNG allocation, but still lays out the entire Markdown document; larger synthetic layouts took roughly 0.8 s in one headless burst run. Arbitrary documents and sustained event load remain unvalidated.
- The installable split integration requires `image.nvim` and ImageMagick; the standalone CLI does not use them.

## Next steps

1. Validate the repository plugin interactively in Kitty on the user's real Markdown documents, including edits, wrapped-row scrolling, resize, local images, and close/reopen.
2. Address observed real-document gaps before release; raw HTML remains an explicit unsupported case.

The earlier prototype's reported 0.0 px soft-wrap error was calculated against its own leaf-matching result, not an independent reference. Do not treat it as proof of exact alignment. The new native/Lua regression checks source columns and actual Neovim wrapped-row scrolling, but general subpixel screen-row accuracy still requires independent validation.

## Dependencies and references

- [cmark-gfm](https://github.com/github/cmark-gfm)
- [litehtml v0.10 Cairo adapter](https://github.com/litehtml/litehtml/tree/v0.10/containers/cairo)
- [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [image.nvim](https://github.com/3rd/image.nvim) was used only for the temporary split experiment.
