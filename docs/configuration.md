# Configuration

[Back to README](../README.md) · [Development and verification](development.md)

Configure mdview.nvim once with `require("mdview").setup({...})`. Setup is optional;
without setup or environment opt-ins, the reader uses stock CSS and PNG transport,
with smoothing and lower-layer placement inactive. Options apply on the next
preview opening; close an existing session before reopening with changed options.
No option installs packages or builds a renderer.

## Setup options

| Option | Default / omitted behavior | Meaning |
| --- | --- | --- |
| `mode` | `"replace"` | `"replace"` reader or `"split"` source/preview. |
| `split_follow` | `"viewport"` | Follow the first displayed source line, or `"cursor"` for minimum active-content reveal. Split only. |
| `theme` | Preserve configured CSS | `"dark"`, `"light"` or `"nvim"` color overrides. |
| `stylesheet` | Plugin's `styles/markdown.css` | Path to the base stylesheet. |
| `renderer` | Plugin's `build/mdview-preview` | Path to the built native worker, not the optional Mermaid CLI. |
| `preset` | No preset | `"fluid"` supplies `raw=true`, `smooth=true`, `factor=0.6`, `clamp=84`. |
| `raw` | Off unless requested by environment/layers | `true` requests local Kitty RGBA transport; `false` forbids it. |
| `smooth` | Off unless requested by environment | `true` enables reader smoothing; `false` forces it off. No split smoothing. |
| `factor` | `0.4` when smoothing is enabled without a factor | Fraction advanced per smoothing step; fluid uses `0.6`. Use a value in `(0, 1]`. |
| `clamp` | Four terminal rows when smoothing or a clamp experiment is enabled | Maximum advance per reader frame, in **pixels**. A positive setup value also enables clamping. |
| `wheel_step` | Four terminal rows per reader wheel callback | Wheel displacement in rows; does not change arrow/page mappings. |
| `zbelow` | Off unless requested by environment | Request local raw transport and lower-layer placement; explicit `false` overrides the environment. |
| `mermaid` | Literal code fences | `true` uses the bundled renderer; `false` disables diagrams; `{renderer="/absolute/path/to/merman-cli"}` selects a custom executable. See [Mermaid](#mermaid). |

Explicit setup values override preset values and matching environment controls.
`clamp=false` only disables the configured clamp when smoothing and the P3/C
experiments are also off. The `FPLOG_C` experiment fixes the wheel step to two rows.

Combine independent options in one setup call:

```lua
require("mdview").setup({
  mode = "split",
  split_follow = "cursor",
  theme = "nvim",
  preset = "fluid",
  zbelow = true,
})
```

This opts into each feature separately: themes do not enable fluid/layers, fluid
does not enable layers, and smoothing only affects reader mode. `raw=false`
continues to forbid raw even when `zbelow=true`.

## Split following

`split_follow="viewport"` follows the first displayed source line, skipping
zero-height concealed logical lines. Wrapped-row offsets are mapped using source
columns where supported; unsupported attribution fails instead of guessing.

`split_follow="cursor"` listens to source cursor movement and scrolls only enough
to keep active content visible. The raster top remains stable while that content
fits. A heading immediately followed by a Mermaid fence reveals the diagram as
well. If heading and diagram cannot both fit, the diagram takes priority; an
oversized diagram shows its start. This is not cursor-at-top scrolling or
entity/relation-level navigation. Height changes can reveal content without
regenerating diagrams; width changes reflow layout.

Native pixel/resize/cursor regressions and natural Neovim TUI events have been
exercised with image display mocked. Real-Kitty visual acceptance of cursor follow
remains pending; exact alignment across arbitrary conceal/virtual text is not
certified. The [Mermaid report](../MERMAID-RESEARCH.md) retains that evidence.

## Document themes and custom CSS

Omitting `theme` leaves the stock or custom stylesheet unchanged. `dark` reproduces
stock colors; `light` supplies an opaque light reading palette. Explicit themes
append color-only overrides after the base stylesheet, so the stylesheet remains
responsible for fonts, sizes, spacing and border widths.

```lua
require("mdview").setup({
  stylesheet = "/absolute/path/to/markdown.css",
  theme = "nvim", -- omit to keep custom stylesheet colors
})
```

`nvim` resolves effective linked **global** highlights:

| Highlight | Document role |
| --- | --- |
| `Normal` | Background and text. |
| `Title` | Headings. |
| `Underlined`, then `Identifier` | Links. |
| `Comment` | Secondary and quote text. |
| `NormalFloat` | Code and table-header surfaces. |

Missing colors use the built-in palette chosen by Neovim's `background`. Missing
or transparent `Normal.bg` does not imply black. Equal surfaces and decorative
borders are derived by blending background/text. Relative sRGB luminance checks
provide at least 4.5:1 adaptive text/quote/code contrast against their backgrounds,
using fallback colors when necessary. Highlight bold/italic attributes are not
copied; neither document transparency nor code syntax highlighting is included.

Colors resolve on open, `ColorScheme` and `OptionSet background`. Only a changed
palette triggers a coalesced reload, preserving the reading target and rejecting
outdated frames. Theme reload incurs whole-document relayout; there is no highlight
lookup or CSS write per scroll frame. Effective CSS is session-owned and removed
on close. Direct highlight changes without those events require close/reopen.

The dark/light/nvim palettes were user-reported working in Kitty; this does not
validate every theme or contrast/geometry combination. See the
[manual palette checklist](development.md#themes).

## Fluid and transport fallbacks

```lua
require("mdview").setup({ preset = "fluid" })
-- Equivalent explicit setup (choose one):
require("mdview").setup({ raw = true, smooth = true, factor = 0.6, clamp = 84 })
```

Fluid uses exponential reader steps paced at 16 ms, keeps one DRAW in flight,
clamps per frame and snaps the remaining distance below 1 px. Factor 0.6 was the
user-preferred reference in real Kitty, not a global default or a latency/FPS
guarantee. Smaller factors remain valid tuning values but can lengthen settling.
The implicit factor for bare smoothing remains 0.4.

Raw requires local Kitty identification (`TERM=xterm-kitty` or `KITTY_WINDOW_ID`),
its graphics protocol and access to Neovim's temporary files. SSH markers
(`SSH_CLIENT`, `SSH_TTY`, `SSH_CONNECTION`), tmux (`TMUX`) or missing Kitty
identification select PNG/image.nvim instead. Requested smoothing stays enabled;
PNG fallback does not inherit local raw measurements. Detection is environment-
based, not full graphics-capability negotiation. The fallback still needs a
working configured image backend; arbitrary non-graphics terminals are not
supported by this check.

image.nvim and ImageMagick remain plugin requirements. Missing image.nvim,
renderer, stylesheet or usable cell-pixel dimensions produces an explicit
diagnostic. No remote raw file-path transmission is attempted. Normal raw
operation uses quiet transmissions; benchmark ACKs are measurement-only.
See [performance evidence](../REPORT.md) for measured conditions and limitations.

## Layers and viewer cursor

`zbelow=true` requests raw transport and places the raster below non-default cell
backgrounds **only after detecting** terminal RGB through OSC 11 and opacity
through Kitty XTGETTCAP. A viewer-only highlight namespace matches that background;
it does not alter global theme highlights or the document's CSS colors.

Missing/invalid responses retain normal `z=-1` placement with a warning; no fixed
black is guessed. `ColorScheme`, focus and terminal theme notifications trigger
redetection; a one-second poll checks background/opacity changes. Close restores
the previous window namespace. No float event hides the entire document.

Popup compositing with zbelow was user-reported working in their normal Kitty
configuration. Earlier real-terminal checks included Rose Pine and Kitty
`background_opacity=0.65`, document-region pixel equality and popup occlusion.
The LSP probe used synthetic content through the floating-preview API, not a live
server response. These observations are not universal compositor/theme/opacity
or live-LSP compatibility guarantees. See [manual layer checks](development.md#reader-and-layers).

Reader and focused-preview cursor hiding requires `termguicolors`; the plugin does
not enable that option for you. Cursor settings are restored for command-line,
source/float focus and close, preserving newer external guicursor changes.

## Mermaid

Follow the [optional build instructions](../README.md#mermaid-diagrams-optional)
first. The evaluated pin is Merman `v0.8.0-alpha.7`, commit
`580e39b69cc1b0ca35c4f8272683e622b2e9b8db`, built with ER, SVG and PNG features.
Other diagram families require a compatible build; complete official Mermaid
semantics/visual compatibility is not promised.

Enable with `mermaid = true` in your existing setup call. The executable is
resolved relative to the plugin checkout, not Neovim's working directory:
`build/merman-evaluation/target/release/merman-cli`. Nothing is downloaded or
built when opening a preview; a missing executable reports the build command.
Omitting the option leaves it disabled on initial setup; explicit `false`
disables it after a previous opt-in.

For a separately built compatible executable, use this instead:

```lua
mermaid = {
  renderer = "/absolute/path/to/merman-cli",
},
```

Fenced blocks whose first info word is exactly `mermaid` pass their unchanged
content to the configured executable, without a shell, during **LOAD**. Generated
PNGs are session-owned; no image export or Markdown source rewriting is required.
Unsaved edits, width changes and explicit document-theme changes regenerate
diagrams. Scroll and height-only resize reuse layout. Rapid edits coalesce; old
frames are not displayed. Failures invalidate the old layout, clear old artifacts
and identify the block's opening line. Correction recovers in the same worker;
close stops pending child groups and removes generated files.

Every source line in a diagram maps to the **whole block**, not a rendered entity
or relationship. Background follows explicit dark/light/nvim themes; luminance
selects Merman dark/default foreground colors, not a complete copy of the document
palette. Without an explicit theme, diagrams use stock `#0d1117`, even with custom
stylesheets. Relationship-label overlap was observed before mdview composition
and remains a renderer layout limitation.

### Resource limits

| Limit | Value |
| --- | --- |
| Source per fence | 1 MiB. |
| Diagrams per LOAD | 16. |
| Retained diagram pixels per LOAD | 16 Mi pixels. |
| PNG width / height / pixels | `max(1, viewport_width - 64)` / 4096 / 4 Mi pixels. |
| Child address space / output file | 768 MiB / 24 MiB. |
| Child CPU / wall time | 6 CPU seconds / 6 seconds. |
| Total Mermaid preparation | 15-second LOAD budget. |

PNG headers are checked before decoding. The child address-space cap covers opaque
intermediate allocations, but is not evidence of low peak memory or an executable
sandbox. Caps can reject large graphs; they do not bound whole-document Markdown
layout. Use a trusted renderer executable. [Research and runtime evidence](../MERMAID-RESEARCH.md)
record tested semantics, visuals, cancellation and resource behavior.

## Advanced environment controls

Use one experiment enable switch per comparison and keep transport fixed when
comparing scroll treatments. Parameters tune that treatment; they do not change
plugin defaults.

| Variable | Meaning |
| --- | --- |
| `FPLOG_RAW=1` | Request local raw RGBA independently of fluid. |
| `FPLOG_SMOOTH=1` | Enable reader smoothing; implicit factor 0.4. |
| `FPLOG_SMOOTH_FACTOR` | Fraction per step; reference 0.6. |
| `FPLOG_SMOOTH_INTERVAL` | Timer interval constrained to 16–20 ms. |
| `FPLOG_CLAMP_PX` | Maximum advance per frame in pixels when clamping is active. |
| `FPLOG_CLAMP` | Legacy clamp tuning in terminal rows; pixel tuning takes priority. |
| `FPLOG_P3=1` | Standalone per-frame clamp experiment. |
| `FPLOG_STEP=1` / `=2` | One-/two-row reader wheel step. |
| `FPLOG_C=1` | Combined two-row wheel step and four-row clamp. |
| `FPLOG_RAW_ZBELOW=1` | Request raw/lower layers, unless explicitly disabled in setup. |

From the checkout, inside local Kitty with mdview.nvim/image.nvim configured:

```bash
FPLOG_RAW=1 FPLOG_SMOOTH=1 FPLOG_SMOOTH_FACTOR=0.6 FPLOG_CLAMP_PX=84 nvim '+MdViewOpen replace' README.md
# Separate layer treatment; do not inherit other experimental controls:
FPLOG_RAW_ZBELOW=1 nvim '+MdViewOpen replace' README.md
```

Prefer the [manual launchers](development.md#reader-and-layers) when isolating
comparisons: they clear inherited experiment variables. Historical F1/F3/PNG0/P2
flags belonged to isolated profiling copies and are **not installed runtime
controls**. `FPLOG_C` is a scroll treatment, not the invalid historical PNG0
experiment. [The report](../REPORT.md#alternatives-not-selected-for-the-reference)
retains candidate measurements and their comparability limits.
