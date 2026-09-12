---
name: floe-video
display_name: Video Studio
description: Inspect media and use verified video transcode, remux and audio conversion paths; check device and model readiness before processing.
---

## Media workflow

1. Discover the tools registered in the current build and call `media.capabilities`. False flags, empty resource lists and missing tools mean unavailable. Do not infer readiness from the operating-system version or a catalog entry.
2. Inspect the source with `video.inspect` or `audio.inspect`. Ground codec, dimensions, frame rate, duration, sample rate and channel choices in the actual input and the user's goal.
3. For supported conversions, use `video.transcode`, `video.remux` or `audio.convert` with explicit input/output and requested parameters. Read the current tool schema; reject unsupported combinations before processing. Keep the source and use a distinct output path in the current workspace.
4. Reopen and inspect the real output. Confirm requested properties and playback where possible. A returned success description does not establish frame count, audio/video synchronization or long-file correctness.

## Availability and limits

The 1.7 media integration remains under qualification. Bounded video and audio conversions have focused host tests; these are not complete device, background, long-file or all-codec acceptance.

Do not advertise interpolation, super resolution, restoration, arbitrary edit plans, audio stems, a complete timeline editor or shared background-media jobs as connected capabilities. Enhancement requires an actually registered runner and verified installed resources; source code and candidate model metadata are insufficient. Query device/model state again before any future supported enhancement, and distinguish installation from successful inference.

Models are optional downloads through the signed model service when that service is configured and qualified. Do not install media weights through apt, invent download links or treat the 33 candidate entries as ready models. Missing signing configuration or assets is an error, not a reason to skip verification.

No native Linux executable or full FFmpeg filter graph is implied. Report unsupported requests precisely and preserve recoverable source files on failure or cancellation.
