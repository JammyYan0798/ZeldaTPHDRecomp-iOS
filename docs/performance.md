# TPHD iPad performance and device notes

[简体中文](performance.zh-CN.md) · [Project overview](../README.md)

## What the frame-rate modes mean

The game simulation runs at 30 logic steps per second. The 60 mode inserts one interpolated draw between logic steps for selected camera, model, material, particle, and 2D-pane transforms. Several effects and animation paths remain at 30 Hz. A display counter or swap-rate sample near 60 does not mean the game logic itself runs at 60 Hz, and it does not establish a locked 60 FPS across scenes.

For a conservative first run, turn interpolation off to use the 30 mode. If GPU load is high, turn off Native resolution and choose a lower fixed render scale in the in-game display settings. These are starting points, not device-specific tuning results.

## Native resolution and MetalFX

Native resolution derives the internal game render size from the current display drawable and the selected aspect/fill geometry, subject to the port's dimension and pixel limits. A drawable's output dimensions, an overlay scale label, and the internal render-target dimensions are different facts.

MetalFX spatial scaling is an optional presentation pass. The current code only attempts it when the presentation is larger than the source texture on both axes and the device can create a compatible scaler. If the pass fails, presentation falls back to the ordinary sampler. A saved preference or an overlay label alone does not prove that MetalFX ran on a particular frame.

## Short TPHD observation: Build 16 and Build 17

One short pair compared Build 16 and Build 17 on an M5 iPad Pro running iPadOS 27.0.1. Both phases showed the same rocky/canyon view, but the source of that scene was not identified. The app used an ordinary launch with empty arguments and environment, sent no input, warmed up for 10 seconds, then observed for 35 seconds. Seven samples per phase were retained after frame 600.

| Phase | Build | Median GPU time | Median render CPU time | Median swaps/s |
|---|---:|---:|---:|---:|
| B1 | 16 | 11.6 ms/frame | 1.83 ms/frame | 59.7 |
| A1 | 17 | 11.3 ms/frame | 1.85 ms/frame | 59.9 |

The cache overlay showed 302 shaders for B1 and 341 for A1, so shader-cache state was not demonstrated to be equal. A later Build 16 observation showed a different village/top-down scene and 730 cached shaders; it was excluded from the pair. No matching Build 17 phase was collected for that scene. The small differences in this short pair do not establish a repeatable optimization benefit, a regression, a minimum specification, or performance in other areas of the game.

The recorded preference values were `nativeResolution=1`, `aspect=1`, `resScale=1.0`, `scaleFilter=2`, `interpFps=60`, `fps60=1`, and `metalFxSpatial=1`. The visible overlay reported an M5 device, 2420×1668 output, a `2.0x` label, and an instantaneous 59.75 FPS reading. Effective internal render dimensions and per-frame MetalFX activity were not independently read back; those labels and preferences must not be treated as confirmation that the requested scaling path was active.

## Other observations and limits

- A maintainer reports no visible flicker in the horse stamina bar or dialogue during a 60-mode gameplay session, followed by a save and return to the Home screen. This is a human confirmation, not a controlled benchmark.
- A maintainer's impression that TPHD feels lighter than the current Wind Waker HD port is subjective. No same-scene or same-device cross-game benchmark supports a lower minimum hardware requirement.
- A separate ordinary 35-second startup observation does not provide a publishable full frame-time distribution, low-percentile frame data, or physical-memory time series.
- The documented reference is one M5 iPad Pro on iPadOS 27.0.1. The iOS deployment target is 17.0, but operation on iOS 17 has not been confirmed here. No minimum iPad model, A-series generation, or physical-memory threshold is established.
- Whole-story play, every physical controller button, rumble, adaptive R2 behavior, long-run performance, and thermal stability remain unverified.
