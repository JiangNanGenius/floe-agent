name: floe-video
display_name: Video Studio
description: Inspect, play, edit, transcode and enhance video on device with Apple-native frame processors plus optional skill-hub models (interpolation, super resolution, restoration).
---

## Video workflow
- **Discover first.** `media.capabilities` reports what this device can actually do: Apple-native frame processors (frame rate conversion, low-latency interpolation, super resolution, low-latency super resolution, optical flow, temporal noise filter, motion blur), MetalFX frame interpolation, hardware H.264/HEVC encode and AV1 decode, Vision person segmentation, supported scale factors, system model status, and which skill-hub models are installed or installable. Never assume a capability.
- **Never use presets.** Every `video.*` and `audio.*` parameter is explicit and comes from you. There are no default frame rates, resolutions, bitrates or codecs. If a required value is missing the call fails with a structured error; if the device cannot honor a value, the error lists what is available.
- **Inspect before editing.** `video.inspect` returns container, duration, dimensions, frame rate and track counts. Read it so every parameter is grounded in the real source.

## Tools
- `video.inspect` — source metadata.
- `video.edit` — apply an explicit non-destructive operation plan and export: trim, concat, reorder, speed, crop, scale, rotate, flip, color, volume, fadeAudioIn/Out, mute, replaceAudio, overlayImage, overlayText, watermark, transition, subtitles, gif, frameRate. The result reports the effective operations and any operation a dedicated pipeline will handle.
- `video.extractFrames` — exact frames at explicit timestamps or a fixed interval (explicit start/end and maximumFrames required).
- `video.transcode` / `video.remux` — container/codec changes with explicit parameters.
- `video.interpolate` — frame rate conversion. Modes: quality (VTFrameProcessor frame rate conversion), lowLatency, metalFX, coreml (requires an installed model id). Pass targetFPS and phases explicitly.
- `video.superResolution` — upscaling with explicit scaleFactor and quality; coreml mode requires an installed model id; report system model download state honestly.
- `video.thumbnail` / `video.proxy` — preview helpers for the player and editor.
- `audio.inspect` / `audio.edit` / `audio.convert` / `audio.mix` — waveform, loudness (LUFS), trim, gain, fades, EQ, dynamics, time/pitch, stems and mixes with explicit parameters.
- **Player and editor.** The in-app player and timeline editor use the same engine and the same capability report. Long renders, interpolation and super resolution belong in `jobs.submit` so progress and cancellation stay visible.

## Models
Additional models (RIFE interpolation, Real-ESRGAN super resolution, restoration, audio) are managed through the signed skill-hub catalog, not through apt:
- `media.models action=list` shows installed/available entries with capability, size, license and status.
- `media.models action=install` requires an explicit model id; downloads are verified against the signed catalog and can be scoped to this session, the project, or shared.
- `media.models action=remove` releases the reference; shared content is garbage collected only after the grace period.
- Prefer one shared install of a large model over per-session copies.

## Honest limits
- Apple's VTFrameProcessor models may need a system download; report `configurationModelStatus` as-is and do not claim availability before it is ready.
- Software paths (VP9/AV1 encoding, model inference) are CPU/GPU bound; pass realistic workloads and prefer background jobs.
- No full FFmpeg filter graph, no exotic codecs (RealVideo/WMV), no RTMP/RTSP streaming, and no generative video.
- Native ELF binaries and servers cannot run on iOS; use an approved remote host for anything outside this engine.
