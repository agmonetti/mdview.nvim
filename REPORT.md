# mdview.nvim — performance and historical evidence

This report retains measurements, decisions and earlier prototype observations.
It is not an installation guide or a current performance guarantee. See the
[README](README.md), [configuration guide](docs/configuration.md) and
[development guide](docs/development.md) for current usage and reproduction.
The final appendix describes pre-integration experiments; its `/tmp` paths are
historical references, not supported commands or evidence that today's plugin
still lives outside the repository.

## Decision / defaults

The user manually compared the variants in real Kitty: smooth06 “va genial”, smooth04 also good, base “un poco peor”. **Factor 0.6 is the reference for opt-in smoothing**, not a new global default. Raw and smoothing remain disabled unless explicitly requested. No dotfile/configuration was changed. The decision to make raw + smooth default belongs to the user after several days of real use.

```lua
require("mdview").setup({ preset = "fluid" })
-- Equivalent explicit configuration (choose one):
require("mdview").setup({ raw = true, smooth = true, factor = 0.6, clamp = 84 })
```

`clamp` in setup is pixels; `FPLOG_CLAMP` remains terminal rows, `FPLOG_CLAMP_PX` is pixels. The preset supplies four values; explicit fields override it, and explicit setup values take priority over matching environment controls. Configuration applies on the next preview opening. `raw=false` / `smooth=false` force those features off even with environment opt-ins; `clamp=false` disables a configured clamp when smoothing/P3/C are also off. Without a preset/configuration/environment opt-in, existing defaults remain intact. The old bare `FPLOG_SMOOTH=1` implicit factor remains 0.4 for compatibility; the documented reference uses preset fluid or explicit factor0.6.

## Requirements / fallback boundaries

- Fluid raw transport: local Kitty supporting `f=32,t=t`, with access to the same temporary files as Neovim. Native renderer built explicitly, Neovim0.10+, configured image.nvim Kitty backend and ImageMagick remain required.
- SSH (`SSH_CLIENT`, `SSH_TTY`, `SSH_CONNECTION`) and tmux (`TMUX`) use the existing PNG/image.nvim path instead of raw. Smoothing remains enabled if requested, but PNG has different throughput; local raw timings do not apply to that fallback. tmux raw is deliberately not enabled without separate transport/geometry validation.
- No Kitty identification (`TERM` / `KITTY_WINDOW_ID`): no raw, PNG path. This is environment-based support detection, not a full protocol negotiation. It does not make the Kitty backend work in arbitrary non-graphics terminals.
- Missing image.nvim, renderer, stylesheet, or usable cell-pixel dimensions yields an explicit diagnostic; the plugin does not silently install dependencies or pretend to display successfully. Remote file-path raw transmission is not attempted.
- No raw-specific runtime ACK negotiation is added to normal operation. Measurement wrappers requested ACKs; normal production uses quiet transmissions. Spoofed terminal identification or terminal/container filesystem isolation is not certified.
- Layers (`setup({zbelow=true})` or `FPLOG_RAW_ZBELOW=1`) remain a separate opt-in; fluid does not enable them. Subsequent user feedback accepted popup compositing in their normal Kitty configuration, not arbitrary terminal/theme combinations or universal live-LSP compatibility. Explicit `zbelow=false` overrides the environment switch; without either opt-in the effective default is false. Enabling zbelow requests raw subject to the existing local-Kitty eligibility checks; `raw=false` still forbids raw. Missing/invalid background or opacity detection preserves `z=-1`, never guesses a color.

## Frame intervals: factor0.6, clamp84px

**No new Kitty benchmark sweep.** This report reuses the accepted real-terminal traces from the previous study: raw RGBA, 957×1008 viewport, fourfold README fixture, middle start, no boundary saturation. One usable run per scenario; these are within-run statistics, not repeated-run confidence intervals. Slow scenarios replay20 wheel mapping callbacks at5/10/30Hz; burst replays the existing400-event stream. This is not a live touchpad input-queue measurement.

Intervals below are between **Kitty transmission starts**, not screen presentation. Quantiles use nearest rank; std is sample standard deviation (`n-1`). Counts exclude the initial positioning frame.

| Scenario | Intervals | p50 ms | p95 ms | Max ms | Std ms | DRAW / published / ACK OK |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 5 Hz | 119 | 20.41 | 115.68 | 133.96 | 30.22 | 120 / 120 / 120 |
| 10 Hz | 105 | 18.86 | 21.34 | 32.59 | 1.92 | 106 / 106 / 106 |
| 30 Hz | 41 | 18.44 | 20.10 | 20.60 | 0.77 | 42 / 42 / 42 |
| Burst | 523 | 18.85 | 33.14 | 122.01 | 14.80 | 524 / 524 / 524 |

At5Hz, smoothing often finishes before the next event. To distinguish deliberate idle time from jitter, exclude intervals where the previous published pixel y already equals the latest requested target at its publication time:

| Active movement only | Intervals | p50 ms | p95 ms | Max ms | Std ms | Gaps >32ms | Idle gaps excluded |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 Hz | 100 | 19.91 | 24.43 | 32.56 | 2.58 | 1 | 19 |
| 10 Hz | 105 | 18.86 | 21.34 | 32.59 | 1.92 | 1 | 0 |
| 30 Hz | 41 | 18.44 | 20.10 | 20.60 | 0.77 | 0 | 0 |
| Burst | 500 | 18.78 | 22.78 | 44.54 | 2.89 | 4 | 23 |

**Measured:** every DRAW in these four traces received a reply, was published/transmitted and received an OK ACK. Zero rejected/missing renderer frames or missing/error load ACKs; one DRAW in flight; destinations converged. Events are coalesced into destinations, not a one-input/one-frame queue. This is not proof of zero terminal/compositor presentation drops.

**Measured irregularity:** active gaps exist. The worst5Hz/10Hz gaps involved previous native draws of14.50/14.42ms, followed by17.77/17.72ms from receive to next DRAW. The worst active burst gap was44.54ms; its previous native draw was13.77ms, and receive→next DRAW17.74ms. Submission/event-loop time also contributes: transmission intervals are not identical to DRAW-request intervals.

**Hypothesis, not proven root cause:** a result arriving just before the16ms pacing floor can miss that timer opportunity and wait for the next periodic tick; timer/producer phase and Lua scheduling are consistent with the~32ms episodes. Individual timer firings were not logged, so the trace cannot attribute all jitter to that interaction. No cadence-algorithm change was requested or made here. A producer around21ms does not inherently imply permanent32ms pacing: most active intervals are~19–23ms in these samples.

Factor0.6 settling remains132/127/146ms to final position at5/10/30Hz and113ms in bursts. Final load ACK is136/131/153/117ms; the30Hz ACK marginally exceeds150ms. This is a reference backed by the user's perception, not a universal settling/FPS guarantee.

## Available controls

| Runtime opt-in / tuning | Meaning / status |
| --- | --- |
| `setup({preset="fluid"})` | Recommended one-option raw + smooth0.6 +84px clamp; opt-in only |
| `FPLOG_RAW=1` | Raw RGBA local Kitty transport; PNG fallback under the conditions above |
| `FPLOG_SMOOTH=1` | Exponential reader smoothing, one DRAW in flight |
| `FPLOG_SMOOTH_FACTOR` | Fraction per step; reference0.6, legacy implicit0.4 unchanged |
| `FPLOG_SMOOTH_INTERVAL` | Timer interval constrained to16–20ms |
| `FPLOG_CLAMP_PX` / `FPLOG_CLAMP` | Pixel clamp / legacy terminal-row clamp |
| `FPLOG_STEP=1` / `=2` | D one-row wheel reference / P1 two-row reference |
| `FPLOG_P3=1` | Standalone per-frame clamp comparison |
| `FPLOG_C=1` | Combined two-row wheel step + four-row clamp; not the PNG0 encoding experiment |
| `setup({zbelow=true})` / `FPLOG_RAW_ZBELOW=1` | Separate lower layer with detected terminal background; default inactive, not enabled by fluid; explicit false overrides the flag |

One experiment enable switch per comparison. Parameter variables tune that treatment; keep transport constant when comparing scroll variants. F1/F3/C_PNG0/P2 were flags in isolated historical profiling copies, **not supported toggles in the current installed plugin**.

## Alternatives not selected for the reference

Historical encoding/transport data: five runs, first discarded, medians of per-run statistics at957×1008 unless stated otherwise. They use a different fixture/workload from the frame-interval study; do not mix their latency columns as one benchmark.

| Candidate / historical flag | Evidence | Decision and limitation |
| --- | --- | --- |
| F1 / `FPLOG_F1_CAIRO` | Cairo direct PNG native p95 **80.90ms**, input→loadACK p95 **121.50ms**, vs PNG baseline **43.74/86.81ms**. Encode p95 **68.50ms**. | Not selected: bypassing pixbuf did not compensate for slower encoding. F2 raw native p95 **21.60ms**, input→ACK **38.68ms** in that study. |
| F3 / `FPLOG_F3_SHM` | POSIX shared-memory raw native p95 **21.17ms** vs F2 tmpfs-file **21.60ms**, difference **0.43ms**; at1500×1000 difference **1.03ms**. Both smaller than earlier baseline p95 IQR **2.58ms**. | Not selected: marginal gain does not justify more shared-memory lifecycle complexity. These measurements do not establish a TLB/mmap causal explanation. |
| PNG0 / `FPLOG_C_PNG0` | **Not tested:** stored `check-C-0.dat` and `check-base-0.dat` were byte-identical PNGs (282105 bytes, same SHA-256). The recorded native/input→ACK timings do not compare distinct compression treatments. | Neither selected nor rejected on performance: compression0 was not demonstrated. GdkPixbuf exposes PNG compression control; production `src/preview.cpp` fixes `"compression", "1"`. Whether the vanished historical experiment actually changed that call cannot now be verified. |
| P2 / `FPLOG_P2` | Event-interval buckets1/2/3 rows. Historical displacement p95 **220.5px** vs saturated base **252px**; latest-input→ACK p95 **49.47ms** vs **46.65ms**. | Not selected for the reference: still quantized per-event movement and no latency improvement in that sample. Old saturation confounds strict ranking; this is not a conclusive controlled rejection of every adaptive-step approach. |
| Smoothing0.25 | Final-position settle **344/381/414ms** at5/10/30Hz, burst**423ms**. | Not the reference: exceeds~150ms settling target. Still accepted as a tuning value. |
| Smoothing0.4 | Settle **200/194/222ms**, burst**207ms**. User nevertheless reported good perception. | Not the reference in favor of0.6: longer measured tail, **not** visually rejected or removed. Legacy implicit factor preserved. |

F2 file transport was chosen; `/tmp` on the measured machine was tmpfs. This does not guarantee tmpfs or equivalent speed on another system.

GdkPixbuf's [`gdk_pixbuf_save`](https://docs.gtk.org/gdk-pixbuf/method.Pixbuf.save.html) documents the PNG `compression` parameter with values 0–9; `src/preview.cpp` currently passes `"compression", "1"`. Therefore “GdkPixbuf offers no real compression control” is not a supported reason to discard PNG0. The safe decision is to exclude C_PNG0 from the ranking because its intended intervention was not established, not because of its timings or an alleged API limitation.

## Artifacts and checks

- Interval analysis: `/tmp/mdview-smooth06-intervals.py`, `/tmp/mdview-scroll-v2.6ml0hzg4/{INTERVALS.md,smooth06-intervals.json}`; reads existing data only.
- Raw interval sources: `/tmp/mdview-scroll-v2.6ml0hzg4/results.json` plus the accepted fixed-window5Hz replacement `/tmp/mdview-scroll-repair.688j__95/results.json`.
- Historical encoder sources: `/tmp/mdview-pipeline-experiments/case-{baseline,F1,C,F2}/results-table.md`, PNG comparison artifacts beside them.
- F3 source: `/tmp/mdview-pipeline-fase1b/case-F3-957x1008/results-table.md`; other sizes in that directory.
- P2 source: `/tmp/mdview-touchpad-study/case-P2_rate/{results-summary.json,mdview-profile.lua}`; old baseline summary in `case-touchpad_base`.
- Repository regression covers preset values, explicit overrides, unknown-preset rejection, tmux PNG fallback, unchanged defaults and existing smoothing/cleanup behavior. No new real-Kitty benchmark sweep or layer changes were made for this task.

Temporary artifacts may disappear; the figures and limitations above remain recorded here. Manual opening without environment-variable combinations:

```vim
:lua require("mdview").setup({preset="fluid"})
:MdViewOpen
```

## Persistent harness rerun — 2026-09-30

Run: `./scripts/bench-scroll --factor 0.6 --output tests/bench/results/factor06-readme-20260930`. Retained [summary](tests/bench/results/factor06-readme-20260930/summary.json), per-scenario raw traces, fixture and version metadata live inside the repository. No runtime defaults were changed.

One real local-Kitty sample per scenario, raw RGBA, factor0.6, clamp84px; actual viewport **948×1012**, cell12×23px. Fourfold snapshot of the then-current README; document height **35110.2px**, middle start y17496. Slow streams:20 wheel callbacks at5/10/30Hz. Burst:400 alternating arrow/wheel callbacks at nominal20ms, four100-event down/up/down/up blocks. The historical exact direction sequence and README fixture no longer exist; this is a recreated workload, not a byte-identical replay.

| Active movement | Intervals | p50 ms | p95 ms | Max ms | Sample std ms | Historical active p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 Hz | 100 | 33.79 | 60.80 | 64.85 | 9.09 | 24.43 |
| 10 Hz | 58 | 36.70 | 48.97 | 49.88 | 4.33 | 21.34 |
| 30 Hz | 27 | 38.17 | 47.11 | 48.82 | 5.65 | 20.10 |
| Burst | 223 | 39.75 | 51.83 | 60.91 | 5.51 | 22.78 |

Definitions remain transmission-start intervals, nearest-rank quantiles and sample std; exclude a gap when its previous transmitted y equals the target at publication. At5Hz eight idle gaps were excluded: global p50/p95/max/std **33.98/60.80/64.85/8.85ms**. The other scenarios' global and active sets are identical.

Final-target transmission settle / load ACK: **259.38/270.07ms**, **315.38/321.31ms**, **453.69/459.98ms**, **1232.51/1239.94ms**, respectively. DRAW / received FRAME / transmission / ACK OK counts were **109/109/109/109**, **59/59/59/59**, **28/28/28/28**, **224/224/224/224**. Zero no-op or boundary-saturated callbacks, one layout revision per stream, zero missing/error load ACKs.

**Observed conclusion:** this rerun does **not** confirm the historical ~20ms active cadence. Native FRAME median timings themselves were32.14/35.02/35.85/38.13ms. The present fixture, viewport and burst directions differ; the data do not isolate a controller regression or another cause. No algorithm change, factor retuning or extra performance sweep was made to force agreement. ACK is not screen presentation; synthetic mappings are not physical touchpad input.

**Comparability limit:** the completed controlled diagnosis below found no evidence of a regression between the tested committed revisions. It did not recover the lost historical fixture or traces, so the new factor0.6 values remain causally non-comparable with the earlier ~20ms observations. Those figures are not a current performance guarantee.

**User-reported harness failure and correction:** the first exploratory240-chapter run displayed stale source text superposed with the raster. That sample is excluded from accepted comparison (`tests/bench/results/factor06-20260930/validity.json`). The harness had not explicitly redrawn the TUI after replacing the source buffer inside its synchronous callback-driven run. It now redraws buffer transitions before measurement. The corrected real-desktop screenshot was inspected: only the proportional raster appears in the preview, without stale monospaced source text. Screenshot and rejected artifacts remain local inside the result directories; generated screenshots are not committed. This is one corrected surface observation, not universal visual acceptance.

## Controlled diagnosis — 2026-09-30

Work branch: `bench-diagnosis`. Production renderer/controller, defaults, factor and layer behavior are unchanged. This section records newly executed measurements, not extrapolations from the lost historical traces.

### Conditions and A/B contract

- **A:** `d01a8b02fd564870adf8ab4d75eff61f57b4d225`, the first committed raw+smoothing controller. `a26f481` has the native worker but no Lua controller, so cannot run this workload.
- **B:** `bench-harness` at `d7ab0b9911cab9104cec76228a2949175618e361`.
- Identical native-source blob `a8a97adbeeedfe8168f57dfbc9f4ddb0cdf13c86` and CSS blob `c6fbbd27757c57659e595beda38787892da42e1a`. Both arms use the same rebuilt/up-to-date Release binary and installed libraries; its SHA-256 is recorded per launch. The only production Lua differences concern opt-in zbelow setup/validation; layers are off in both arms.
- Same frozen `tests/bench/fixture.md`, raw RGBA, factor0.6, clamp84px, 16ms smoothing timer, middle start; observed viewport **948×1012**, cell12×23px. Same callbacks/directions as the persistent harness. Five launches per arm, each covering all four scenarios; first launch per arm discarded, four retained. Alternating round order A/B, B/A, A/B, B/A, A/B.
- **Affinity succeeded:** Kitty CPU0, Neovim CPU1, renderer CPU2 in every launch, verified through `/proc/<pid>/status`. These are physical cores0/1/2; SMT siblings4/5/6 were not reserved. Pinning is not exclusive-core isolation.
- Governor **powersave**, unchanged. Sampled frequencies on CPUs0/1/2 ranged approximately **0.80–1.80GHz**. Before/after launch load averages ranged **4.14–5.82 / 5.35–6.26 / 5.56–5.84** (1/5/15min). CPU busy fractions over launch windows: CPU0 **31.1–51.5%**, CPU1 **30.9–51.1%**, CPU2 **86.2–91.5%**. This was an active desktop, not an idle-machine benchmark.
- Runtime files are in the repository on **ext4**, `/dev/nvme0n1p2`, not historical `/tmp` tmpfs. Both A/B arms share that condition. Native profiling below also uses repository ext4; no filesystem/governor/system settings were changed.
- All **3,766** retained input-phase DRAWs produced FRAMEs, transmissions and OK load ACKs. Zero missing ACKs, no-op callbacks or boundary callbacks; fixed viewport/revision. A real desktop capture from B run5 was inspected: proportional raster present without source-text superposition. No new touchpad-perception or presentation-timing claim.

Numbers below are **medians of the four retained per-run statistics**. Quantiles are nearest rank; `CV = 100 × sample_std(per-run statistic) / mean(per-run statistic)`, `n-1`. CV is between-run variability, not within-run jitter or an equivalence confidence interval.

### A/B active transmission cadence

| Scenario | A p50 ms | A CV p50 | A p95 ms | A CV p95 | B p50 ms | B CV p50 | B p95 ms | B CV p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 Hz | 32.97 | 3.87% | 42.15 | 5.50% | 33.02 | 0.76% | 39.71 | 2.50% |
| 10 Hz | 32.98 | 1.33% | 40.75 | 4.30% | 33.32 | 1.23% | 40.88 | 8.00% |
| 30 Hz | 33.09 | 1.89% | 40.39 | 5.70% | 32.22 | 5.83% | 36.87 | 5.58% |
| Burst | 33.59 | 1.84% | 43.48 | 3.82% | 33.41 | 1.73% | 39.87 | 5.40% |

These are consecutive Kitty transmission starts while movement remains active, excluding a gap whose previous published integer y already equals its then-current target. They do not measure screen presentation.

### Settling: endpoint definitions and normalization

The existing harness's `final_target_settle_ms` is exactly:

`first transmission.start_ms >= last_input.time_ms with transmission.y == last_input.target_y, minus last_input.time_ms`.

It does **not** mean the time the controller first sets its internal floating-point `current_y` to the target. `final_target_ack_ms` adds the delay until that transmission's load ACK is delivered to Neovim.

The diagnosis also computes `final_request_settle_ms`: first post-input **DRAW requesting the final integer raster y**, minus the last-input timestamp. This removes the final frame's production/delivery time. It is a raster-request endpoint, **not** the exact internal subpixel snap: the controller can already have requested the final integer y before snapping, and that later snap need not issue another DRAW. An attempted equality-only `current_y`/DRAW metric was therefore null in some traces; aggregation was corrected from the retained raw traces, without rerunning or discarding valid runs.

| Arm / scenario | Final raster request ms | CV request | Final transmission ms | CV transmission | Final load ACK ms | CV ACK |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A / 5 Hz | 207.43 | 6.40% | 240.93 | 5.80% | 248.79 | 5.70% |
| B / 5 Hz | 202.21 | 7.50% | 238.46 | 6.74% | 245.38 | 6.33% |
| A / 10 Hz | 214.48 | 7.60% | 244.77 | 6.76% | 252.43 | 6.69% |
| B / 10 Hz | 219.09 | 8.04% | 251.98 | 6.73% | 258.11 | 6.86% |
| A / 30 Hz | 304.50 | 7.95% | 336.18 | 6.22% | 342.51 | 6.12% |
| B / 30 Hz | 250.01 | 22.91% | 282.58 | 20.73% | 289.88 | 20.27% |
| A / burst | 913.85 | 8.62% | 944.48 | 8.45% | 952.69 | 8.42% |
| B / burst | 832.86 | 6.03% | 861.70 | 5.82% | 868.97 | 5.78% |

The older study described settling as “last event until final position,” with ACK separately. Its script/raw traces are gone: whether that position timestamp meant internal snap, raster request or publication cannot now be independently verified. Do not assert an exact historical endpoint match. Both A/B arms above have been recalculated with **the same explicit raster-request and transmission definitions**.

The retained single-run `factor06-readme-20260930` traces are independently recalculable:

| Scenario | Recalculated final raster request ms | Existing final transmission ms |
| --- | ---: | ---: |
| 5 Hz | 224.84 | 259.38 |
| 10 Hz | 279.37 | 315.38 |
| 30 Hz | 419.07 | 453.69 |
| Burst | 1199.16 | 1232.51 |

Changing the endpoint removes roughly one final native frame, **not** the long burst tail. The vanished historical ~113–146ms position figures cannot be reprocessed under either definition; their comparison remains unresolved, not silently treated as like-for-like.

### Native producer phases: frozen README versus simple document

Separate observation-only Release binary generated by `tests/bench/native_profile.py`; production `src/preview.cpp` and `build/mdview-preview` untouched by instrumentation. Five fresh processes per fixture, first discarded; **33 frames/process**, 330 recorded frames overall. CPU2 affinity verified for every process. Viewport948×1012; 0–100% of document scroll range in 10% steps, repeated three times in the same order. Frozen README offsets: 0/3410/6820/10229/13639/17049/20459/23869/27279/30688/34098. The simple `examples/demo.md` is shorter than the viewport (749.1px), so all offsets are0; it is not a long-document scaling series. Profile load averages before/after were6.14/6.46 (1min), with powersave unchanged.

| Phase | README p50 ms | CV p50 | README p95 ms | CV p95 | Simple p50 ms | CV p50 | Simple p95 ms | CV p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Draw: surface setup + document | 27.41 | 6.25% | 34.30 | 7.02% | 6.76 | 10.12% | 9.52 | 8.04% |
| Cairo → straight RGBA | 4.31 | 14.65% | 6.26 | 7.51% | 6.00 | 6.34% | 8.34 | 10.10% |
| File open/write/close | 1.94 | 7.95% | 3.73 | 15.18% | 1.93 | 17.39% | 3.52 | 7.94% |
| Native total | 34.07 | 6.45% | 42.14 | 8.11% | 15.99 | 6.05% | 20.87 | 12.70% |

Within draw, `doc->draw` alone has p50 **26.46ms** versus **4.67ms**; setup p50 **0.56ms** versus **2.01ms**. Conversion includes surface flush, vector allocation and straight-alpha conversion. Write includes implicit close but **no fsync**: page-cache completion, not durable media latency. Total ends after surface destruction/status checks, before metrics emission; it excludes Neovim/Kitty/terminal transfer. Phase quantiles are independently computed and must not be added. Frame elapsed includes instrumentation reporting overhead, so phase JSON `total_ms` is authoritative.

Stock versus instrumented raw frames were byte-identical at README y0/y34098 and simple y0, three3837504-byte frames; hashes in `equivalence-smoke.json`.

### Conclusion: measured versus hypotheses

**Measured:** the oldest runnable committed controller and bench-harness both produce roughly33ms active p50 under the same conditions. B is not systematically slower; differences in p50 are small and p95 is mostly lower. Source comparison also finds no changed active smoothing/render path. **No evidence of a regression between these committed revisions.** Four retained runs do not prove statistical equivalence or cover the lost pre-commit experimental copies.

**Measured:** the frozen README producer takes about34ms total versus16ms on the simple document; document drawing dominates the difference, while write medians are about2ms for both. A one-frame-in-flight controller cannot publish a sustained cadence faster than its producer. The larger workload is therefore a measured contributor to today's cadence; its content/length/geometry components were not independently isolated.

**Hypotheses / remaining historical limits:** changed fixture, historical benchmark implementation/build/dependencies, scheduling/frequency and tmpfs-versus-ext4 may explain the old/new gap. The present measurements do not rank all these causes. The historical fixture, source instrumentation and traces are missing, so this diagnosis closes the committed-revision A/B question, **not** byte-identical reproduction of the historical18–20ms claim. Elevated desktop load and unreserved SMT siblings remain environmental confounders. No retuning or default change is justified by this comparison.

### Durable evidence and reproduction

- `scripts/bench-diagnose --output tests/bench/results/<new-name>`: full five-run A/B, isolated checkouts and actual real Kitty. `--summarize-only --output tests/bench/results/diagnosis-20260930` recomputes statistics from raw traces without new measurements.
- [A/B comparison](tests/bench/results/diagnosis-20260930/comparison.json), `conditions.json`, per-launch condition snapshots, `A-{1..5}` / `B-{1..5}` raw scenario traces, summaries, versions, SHA-256 and effective-affinity records. These local results persist in the repository; generated checkouts/builds/screenshots are not committed.
- [Native phases](tests/bench/results/native-profile/summary.json), `run-metadata.json`, `build-metadata.json`, `*-run{0..4}-phases.jsonl`, fixture/CSS snapshots and byte-equivalence evidence. Generated source/build are isolated under that result directory.
- Executed regression: `nvim --headless -u NONE -l tests/plugin.lua` and `./tests/smoke.sh` passed. Native byte-equivalence smoke passed. These do not replace the user's daily fluid perception or measure physical touchpad/presentation latency.

Native-profile writes reuse/truncate one repository runtime file, without Kitty deleting it; A/B uses the production sequence-specific filenames consumed by Kitty. The native profile isolates producer phases rather than reproducing that complete file lifecycle. Treat its write timings as the measured profiling workload, not an exact decomposition of every A/B frame.

## Bundled alert Octicons — 2026-10-01

Replaced CSS approximations with five local Primer Octicons, pinned to
[`90af1f14984832de34e94b2d530043fbcf85eb7f`](https://github.com/primer/octicons/commit/90af1f14984832de34e94b2d530043fbcf85eb7f).
SVG sources total **2,550 bytes**, plus the 1,068-byte upstream MIT license.
No package installation or runtime download. Both renderers embed the SVGs;
GdkPixbuf's installed SVG loader is required only when alerts are rendered.
Five lazy, process-lifetime 16×16 A8 masks retain **1,280 pixel bytes**, excluding
object/loader overhead. DRAW tints masks with computed CSS color; it does not
parse SVG or read icon files.

A small native-only comparison used the five-alert synthetic source retained in
`tests/alerts-octicons-observed.json`, 700×800 RGBA output in `/tmp`, five processes
per arm, alternating order, first process per arm discarded. Each process drew
20 identical viewports and then reloaded/drew the source five times. No affinity
or system-load isolation; not real input, terminal display or statistical equivalence.

| Metric | Previous CSS shapes | Bundled SVG masks |
|---|---:|---:|
| Initial LOAD median | 19.73 ms | 44.20 ms |
| Warm LOAD median | 3.39 ms | 2.96 ms |
| DRAW + RGBA write median | 4.17 ms | 4.13 ms |
| DRAW + RGBA write p95 | 5.00 ms | 5.21 ms |

The initial LOAD pays SVG-loader setup; the measured extra cost was about 24 ms.
This sample does not show a material median redraw increase, but cannot prove
equivalent performance. A separate single `/proc` observation after one frame
reported VmRSS 22,712→27,736 KiB and VmHWM 26,796→31,356 KiB. This includes loaded
decoder/library pages, not just masks. Launch `wait4` RSS had an inherited
high-water floor and is excluded from memory conclusions.

Final local binaries grew 233,904→274,048 bytes (preview) and 137,656→199,872 bytes
(standalone); build/compiler-specific sizes, not installed dependency size.
An isolated loader-call observer saw five SVG decodes for 100 alerts and 21
frames, and still five across three LOADs of 100 alerts each. Injected loader
unavailability returned an explicit error; alerts disabled still rendered.

Alert tests compare visible icon/title centers and independent ImageMagick SVG
silhouettes at 360/700 px in dark/light/nvim, allowing rasterizer edge differences.
Plain/marked parity, theme/edit/resize and cleanup regressions passed, as did
plugin/theme/cursor/Mermaid/CLI checks. Native dark/light PNGs were inspected.
Ordinary demo standalone output matched the previous binary with AE=0; the
documented md2png command produced an actual 699×749 PNG. The user approved
their Kitty visual checks and reported that the Octicons look much better.
This is acceptance for their tested configuration, not universal compatibility
or a terminal-latency measurement.

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

