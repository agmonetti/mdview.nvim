# Fluid reader — evidence and opt-in decision

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
- Layers (`FPLOG_RAW_ZBELOW`) remain a separate experiment awaiting the user's manual report. This task did not modify its implementation, and fluid does not enable it. The shared raw eligibility check now rejects tmux/SSH_CONNECTION too; this is the conservative transport fallback, not a new layer behavior or acceptance claim.

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
| `FPLOG_RAW_ZBELOW=1` | Separate lower layer, pending user manual acceptance; not enabled by fluid |

One experiment enable switch per comparison. Parameter variables tune that treatment; keep transport constant when comparing scroll variants. F1/F3/C_PNG0/P2 were flags in isolated historical profiling copies, **not supported toggles in the current installed plugin**.

## Alternatives not selected for the reference

Historical encoding/transport data: five runs, first discarded, medians of per-run statistics at957×1008 unless stated otherwise. They use a different fixture/workload from the frame-interval study; do not mix their latency columns as one benchmark.

| Candidate / historical flag | Evidence | Decision and limitation |
| --- | --- | --- |
| F1 / `FPLOG_F1_CAIRO` | Cairo direct PNG native p95 **80.90ms**, input→loadACK p95 **121.50ms**, vs PNG baseline **43.74/86.81ms**. Encode p95 **68.50ms**. | Not selected: bypassing pixbuf did not compensate for slower encoding. F2 raw native p95 **21.60ms**, input→ACK **38.68ms** in that study. |
| F3 / `FPLOG_F3_SHM` | POSIX shared-memory raw native p95 **21.17ms** vs F2 tmpfs-file **21.60ms**, difference **0.43ms**; at1500×1000 difference **1.03ms**. Both smaller than earlier baseline p95 IQR **2.58ms**. | Not selected: marginal gain does not justify more shared-memory lifecycle complexity. These measurements do not establish a TLB/mmap causal explanation. |
| PNG0 / `FPLOG_C_PNG0` | Recorded native/input→ACK p95 **44.27/91.47ms**, vs baseline **43.74/86.81ms**. Stored `check-C-0.dat` and `check-base-0.dat` are **byte-identical** PNGs (282105 bytes, same SHA-256). | No demonstrated benefit; not selected. The intervention's compression level was not independently established by these outputs. Do **not** claim this proves genuine uncompressed PNG is slower. Cause of identical outputs remains unresolved; no extra rerun was added. |
| P2 / `FPLOG_P2` | Event-interval buckets1/2/3 rows. Historical displacement p95 **220.5px** vs saturated base **252px**; latest-input→ACK p95 **49.47ms** vs **46.65ms**. | Not selected for the reference: still quantized per-event movement and no latency improvement in that sample. Old saturation confounds strict ranking; this is not a conclusive controlled rejection of every adaptive-step approach. |
| Smoothing0.25 | Final-position settle **344/381/414ms** at5/10/30Hz, burst**423ms**. | Not the reference: exceeds~150ms settling target. Still accepted as a tuning value. |
| Smoothing0.4 | Settle **200/194/222ms**, burst**207ms**. User nevertheless reported good perception. | Not the reference in favor of0.6: longer measured tail, **not** visually rejected or removed. Legacy implicit factor preserved. |

F2 file transport was chosen; `/tmp` on the measured machine was tmpfs. This does not guarantee tmpfs or equivalent speed on another system.

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
