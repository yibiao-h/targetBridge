# Experimental 10-bit RGB DPCM transport

`native4_5kRaw60` (**iMac 4.5K DPCM**) targets 4480 × 2520, the
[24-inch M1 iMac's native resolution](https://support.apple.com/en-gb/111895).
`native5kRaw60` (**5K DPCM**) targets 5120 × 2880. Both target up to 60 FPS and request packed
10-bit RGB (`l10r`, ARGB2101010 little endian) from ScreenCaptureKit and
losslessly transmit the captured RGB samples using TBD2 tile-DPCM.
This is an experimental transport, not a guarantee of sustained 4.5K60 or 5K60,
HDR, native 10-bit source content, or 10-bit panel scanout.

For 1:1 capture, enable render matching in Extended Desktop: the 4.5K profile
uses a 2240 × 1260 HiDPI desktop, and the 5K profile uses 2560 × 1440.
The separate **iMac 4.5K** (`retina4_5k60`) preset uses the existing HEVC path;
select **iMac 4.5K DPCM** to request 10-bit RGB capture.

## Capture and color contract

The DPCM session explicitly requests `kCVPixelFormatType_ARGB2101010LEPacked`
and `CGColorSpace.displayP3`. The receiver labels its `BGR10A2Unorm`
CAMetalLayer as Display P3 too. ScreenCaptureKit documents `l10r` as a
supported [output pixel format](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/pixelformat).

Capture startup and delayed callbacks are tied to the current connection and
capture attempt. A stop/reconnect during an asynchronous start discards the old
stream instead of publishing it into the new session.

The sender checks the delivered CVPixelBuffer format and layout before reading
any samples. NV12 and BGRA are rejected rather than interpreted as packed
10-bit RGB. The encoder preserves all 1024 values per RGB channel, including
the low two bits. Alpha is omitted and reconstructed as opaque.

This contract begins **after capture and color conversion**. Choosing a 10-bit
buffer does not create source precision that an application, source display,
or virtual framebuffer did not have. This change does not modify the private
virtual-display transfer-function API. Color conversion, scaling and final
panel scanout are outside the codec's bit-exact guarantee. Capture remains SDR.

## Negotiation and fallback

| Receiver / selected mode | Capture and wire format |
|---|---|
| DPCM preset, receiver advertises a working Metal DPCM decoder | Display P3 10-bit RGB, TBD2 (`0x25`) |
| DPCM preset, old receiver supports raw NV12 | 8-bit NV12, existing raw packet (`0x22`) |
| DPCM preset, receiver supports neither DPCM nor raw NV12 | Existing HEVC/H.264 path, subject to encoder availability |
| Existing preset | Existing encoded path, or explicitly enabled `RAW=1` NV12 |

Absent capability fields mean unsupported. Selection happens before capture
starts, so a packed RGB frame never reaches the planar NV12 sender. The active
codec label distinguishes DPCM RGB 10-bit, NV12 RAW 8-bit and encoded transport.
A receiver without usable Metal continues advertising the legacy formats.
The receive loop yields after a byte/time budget so a continuously readable
video stream cannot starve window events or input; teardown stops dispatching
further packets from the same batch.
Capability probing does not create a visible Metal layer over the status UI.

If GPU encoding cannot be created or fails in a negotiated DPCM session, the
CPU reference encoder emits the same 10-bit TBD2 format. It may be much slower;
backpressure and the existing frame-rate ceiling still apply. There is no
silent conversion to 8-bit NV12. Invalid capture frames are rejected and logged.
The direct CGDisplayStream mirror fallback is used only for encoded sessions;
it does not silently substitute its 8-bit buffers into a DPCM session.

The receiver creates the Metal layer only for incoming DPCM frames, shows it
after a successful frame, and releases it on NV12/encoded fallback, disconnect
or window destruction. The currently integrated whole-frame decoder uses
ordered presentation, avoiding the unfinished asynchronous band-present path.

## Codec

TBD2 splits frames into independent 8 × 8 tiles. Each tile stores its first
pixel and per-channel residual widths. Remaining pixels predict from the left,
except the first column which predicts from above. Modular residuals and zigzag
coding preserve samples exactly at either supported codec depth (8 or 10 bits).
The current Sender DPCM presets accept only 10-bit capture.

Groups of 64 tiles share an offset table. The CPU parser checks dimensions,
widths, payload sizes and group offsets before the Metal decoder accesses the
blob. Display allocations are additionally limited to 5120 × 2880, matching
the current Sender transport, even when a small valid blob describes a much
larger flat image. GPU encoding is compared byte-for-byte with the reference C encoder in
the optional synthetic-pixel test.

| Component | Source |
|---|---|
| Wire format and CPU reference | `TargetBridge-Shared/codec/tb_dpcm.h`, `tb_dpcm.c` |
| GPU encoder | `TargetBridge-Shared/codec/tb_dpcm_gpu.h`, `tb_dpcm_gpu.m` |
| Capture negotiation and buffer validation | `TBVideoTransport`, `TBDPCMFrameEncoder` in `TBDisplaySenderService.swift` |
| Receiver GPU decode and display | `TargetBridge-Receiver/TBReceiverC/src/tb_metal_plane.m` |

## Compatibility and verification

Both Apple Silicon receivers (including M1 iMac) and Intel receivers remain
supported targets. A capability probe, not the CPU model, controls DPCM
availability. Existing CI builds both `arm64` and `x86_64`. No new OS minimum is
introduced. The initial proposal's measurements came from a separate fork on
a 2020 Intel 5K iMac; they do not establish performance on M1 iMac or on this
integration. A 40 Gb/s cable rating is not application throughput.

Hardware-free checks:

```sh
cd TargetBridge-Receiver/TBReceiverC
make test
```

This includes the C codec tests, with complete 0–1023 RGB ramps and malformed
packet coverage. For the GPU encoder, using synthetic pixels only:

```sh
make test-dpcm-gpu
```

The GPU test compares 8-bit and 10-bit GPU output with the CPU reference, injects GPU creation/submission failures, then
checks decoded pixels, padded rows, partial tiles and full 4480 × 2520 frames.
It requires a usable
Metal device; exit 77 means unavailable, not a passing GPU test.

For receiver decode and presentation with synthetic pixels, run
`make test-dpcm-metal`. This requires SDL2 and a logged-in GUI session, opens a
small test window, compares GPU decoded buffers with the CPU reference, and
checks first-frame visibility, teardown, oversized-frame rejection and native
4.5K decode readback (including its final partial group). It does
not capture the screen or change display settings.

Sender XCTest coverage checks capability combinations, the actual SCStream
configuration, rejection of incompatible pixel buffers and CPU fallback
round-trips of all 1024 channel values. See [Testing](Testing.md) for commands.

Before calling the path ready for general use, run real two-machine sessions
on Apple Silicon and Intel receivers. Record source and receiver model, macOS
version, selected display mode, actual capture format, transport, sustained FPS,
queue drops, CPU/GPU cost, color gradients/text, cursor, disconnect/reconnect
and fallback behavior. M1 iMac is one test target, not the sole supported setup.
Synthetic codec tests do not verify screen capture, GPU presentation, panel
precision or sustained two-machine throughput.
