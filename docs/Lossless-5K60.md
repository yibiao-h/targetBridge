# How the 5K60 lossless link works

A 5120×2880 desktop at 60 fps, 4:4:4 10-bit, **bit-exact** — no chroma
subsampling, no quantisation, no generational loss. MacBook Pro (Apple Silicon)
to a 2020 Retina 5K iMac over one Thunderbolt cable.

This is a write-up of what the constraints forced, and what the measurements
said when reasoning and reality disagreed. Every number here was measured on
that hardware.

## The constraint that shaped everything

A 5K frame at 4:4:4 10-bit is **59 MB**. At 60 fps that is **3.5 GB/s** of
pixels — 28 Gb/s, comfortably inside a 40 Gb/s Thunderbolt link. Bandwidth was
never the problem.

The receiver was. On a 2020 iMac, the measured cost of a full frame:

| Stage | Cost |
|---|---|
| Pulling bytes off the wire | **23.4 ms** (single core, inside the TCP stack) |
| Pushing them across PCIe to the GPU | **12.9 ms** |
| Budget for 60 fps | **16.7 ms** |

Two stages, either of which alone blows the frame budget. Both costs are
proportional to frame size, so the cheapest way to raise the frame rate is to
send fewer bytes — but the whole point is losslessness, so nothing can be
thrown away.

That rules out the obvious answer. HEVC would cut the bytes by ~100×, but it is
lossy, its hardware path is 4:2:0 8-bit, and on this iMac it could not hold 60
fps anyway. The codec has to be lossless, and it has to be cheap enough to run
on a GPU that is otherwise idle while the CPU is saturated.

## TBD2: lossless tile-DPCM

DPCM — differential pulse-code modulation — codes each sample as its difference
from a prediction rather than its absolute value. Neighbouring pixels are
usually close, so the differences are small and pack into fewer bits. Because
the prediction is reproducible on the far end, nothing is lost.

Measured compression on real content:

| Content | Ratio |
|---|---|
| 36-megapixel photo (near worst case) | **2.96×** |
| Text-heavy UI | **4.5×** |
| Ordinary window chrome | **13.8×** |

For calibration, LZFSE on that same photo manages 3.48×, so this captures 85%
of what a general-purpose compressor gets — while being arithmetically trivial
enough to run per-tile on a GPU.

That turns the 23.4 ms receive into roughly 8 ms, and the frame fits.

### The problem with DPCM, and the fix

Textbook DPCM is **serial**: pixel N depends on pixel N−1, so a decoder cannot
start anywhere but the beginning. That is fatal on a GPU, which is the only
spare compute the receiver has.

So the frame is cut into **8×8 tiles that are fully independent** — each
carries its own seed pixel and its own bit widths, and needs nothing from any
neighbour. One GPU threadgroup per tile, **230,400 of them** at 5K. DPCM
*within* a tile, parallel *across* tiles.

**8×8 was measured, not guessed.** 4×4 wins marginally on dense text (4.71×
vs 4.46×) but loses badly on flat content (9.7× vs 13.8×), because it pays four
times the per-tile overhead where there is nothing to code. 16×16 loses
everywhere: one high-contrast edge sets the bit width for 256 pixels.

The predictor is the **left neighbour**, with the first column predicting from
above. JPEG-LS's median-edge predictor was measured too and ties it to within
1% on every frame tested, including the photo — inside an 8×8 tile there is not
enough vertical run for it to earn its three extra loads and a clamp.

Residuals are taken modulo the sample range and re-centred, so reconstruction
wraps and stays exact. Zigzagged, the widest possible residual needs exactly the
sample depth — the same as a raw sample — so **a tile can never expand beyond
its header**, and no escape hatch is needed for pathological content.

### Why the decoder had to be on the GPU

Decoding costs roughly **44 million bit extractions** per 5K frame. Measured on
the target iMac: **166 ms single-threaded on the i5**, against **6.5 ms on its
GPU**. The CPU was never an option — and it was already the bottleneck.

## The rest of the pipeline

Points where the measurement contradicted the reasonable guess:

**Capture.** `SCStream`'s `minimumFrameInterval` is a *throttle*, not a request.
Asking for `CMTime(1, 60)` at 60 Hz caused two-period capture gaps; `.zero` is
required. `queueDepth` is resolution-dependent: at 5K the capture callback runs
10–14 ms against a 16.7 ms period, so a shallow queue leaves ScreenCaptureKit
nowhere to put the next frame — and a stalled stream delivers **nothing**, not a
stale frame, which reads as "macOS did not draw it".

**10-bit.** A virtual display is 8-bpc because it is SDR. Declaring a transfer
function is what makes macOS promote the framebuffer to 16-bpc, and it is the
*only* reason the 10-bit path carries real bits rather than 8-bit values
replicated into 10.

**Rendering.** SDL2 cannot present 10-bit, so the receiver replaces its renderer
with a `CAMetalLayer` and drives the drawable at the frame's own resolution.
The cursor is a separate `CALayer` child, composited by Core Animation — so a
pointer move reaches the panel without waiting for a video frame.

**Pacing.** Sends follow a slot *schedule*, not a minimum gap. "At least 0.95 of
a period since the last send" is safe at 60 Hz capture and inverts under
oversampling: a pair of frames landing slightly early forfeits a slot, the next
chance is a whole period later, and the receiver bins it as a drop. Measured
5–8% late frames at 120 Hz against 0.3–1% at 60 Hz.

## The method that actually worked

Most of the expensive mistakes in this project shared one shape: a mechanism
reasoned out, built, then found wrong. Six theories for one connect failure cost
two days. Three fixes for one cursor stall each targeted the wrong layer.

What worked was measuring before proposing a cause — and being specific about
which instruments lie. Several read *healthy* while the thing they named was
broken:

- A cadence histogram with a hardcoded reference period goes blind when that
  period changes, and fails by looking **perfect**.
- A full 60 fps with zero drops is not health: a bad send phase shows
  `drawable 16.6 ms` and 27 ms cursor latency while every rate counter reads
  perfect.
- `nc -z` proves the kernel completed a handshake, not that the app ever called
  `accept()`.
- `netstat -I` reports `Opkts = 0` permanently on this path — a Skywalk
  accounting artefact, not a transmit failure.

## Reading the code

| What | Where |
|---|---|
| Wire format, tile layout, rationale | `TargetBridge-Shared/codec/tb_dpcm.h` |
| CPU reference encoder/decoder | `TargetBridge-Shared/codec/tb_dpcm.c` |
| GPU encoder | `TargetBridge-Shared/codec/tb_dpcm_gpu.h` |
| Metal decode + cursor plane | `TargetBridge-Receiver/TBReceiverC/src/tb_metal_plane.m` |
| Capture, encode, pacing | `TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift` |
| Packet IDs (both ends agree here) | `TargetBridge-Receiver/TBReceiverC/src/proto.h` |

The headers carry the reasoning inline, including the measurements behind each
constant and the alternatives that were tried and rejected.

## What this is not

Not a general-purpose codec. TBD2 assumes a desktop image on a short, reliable
link with bandwidth to spare and a receiver whose GPU is idle. On a lossy
network, or where bandwidth is the scarce resource, a lossy codec is the right
answer — which is why the other presets exist.
