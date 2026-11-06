# Qualification fixtures

`legacy-sample.json` is synthetic compatibility input.

`synthetic-video.mp4` is an original synthetic solid-blue clip, 160×90,
10 fps, five H.264 frames, 0.5 seconds, no audio. Generated during development:

```sh
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i 'color=c=0x2366cc:s=160x90:r=10:d=0.5' -an -c:v libx264 \
  -pix_fmt yuv420p -map_metadata -1 -movflags +faststart synthetic-video.mp4
```

The example reads bundled bytes; it never starts FFmpeg or an interpreter at
runtime. Decode and native preview checks are separate from archive integrity.
