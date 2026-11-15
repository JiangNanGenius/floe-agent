# Stock userspace qualification commands (Linux V4L2 / FFmpeg)

These target the two virtio-media nodes once the primary's VideoToolbox-backed
device is integrated (`/dev/video28` decoder, `/dev/video29` encoder are the
coordinator's planned slots; actual numbering follows kernel registration
order — always resolve via `v4l2-ctl --list-devices` or the fvm_qual enum).

## 0. Enumeration / baseline (no codec data needed)

```sh
v4l2-ctl --list-devices
v4l2-ctl -d /dev/videoX --all
v4l2-ctl -d /dev/videoX --list-formats-ext        # per queue
./fvm_qual enum /dev/videoX
```

## 1. Decode H264 (Annex B elementary stream) — hardware NV12 out

```sh
ffmpeg -hide_banner -c:v h264_v4l2m2m -i clip.h264 -f rawvideo -pix_fmt nv12 out.nv12
ffmpeg -hide_banner -c:v h264_v4l2m2m -i clip.h264 -pix_fmt nv12 -f null -     # no write, timing only
./fvm_qual m2m-decode /dev/videoX clip-with-aud.h264 ./frame-                # writes frame-0000000N.nv12
sha256sum out.nv12            # compare against golden raw NV12 (native-02 evidence set)
```

`fvm_qual m2m-decode` feeds COMPLETE ACCESS UNITS. Its input must either be a
raw Annex-B stream that contains AUD NALs (split on AUD boundaries; any SPS/PPS
before the first AUD rides with the first AU), or an FVMP packet manifest
(`"FVMP" u32(1) u32(count) count x (u32 len, bytes)`). Add AUDs with:

```sh
ffmpeg -i clip.mp4 -c copy -bsf:v h264_metadata=aud=1 clip-with-aud.h264
ffmpeg -i clip.mp4 -c copy -bsf:v hevc_metadata=aud=1 clip-with-aud.hevc
```

## 2. Decode HEVC

```sh
ffmpeg -hide_banner -c:v hevc_v4l2m2m -i clip.hevc -f rawvideo -pix_fmt nv12 out.nv12
```

## 3. Encode H264 NV12 -> Annex B

```sh
ffmpeg -hide_banner -f rawvideo -pix_fmt nv12 -s 1280x720 -r 30 -i in.nv12 \
       -c:v h264_v4l2m2m -b:v 4M out.h264
./fvm_qual m2m-encode /dev/videoY H264 1280 720 30 out.h264
ffprobe -v error -show_streams out.h264     # codec_name=h264, 30 frames
```

## 4. Encode HEVC

```sh
ffmpeg -hide_banner -f rawvideo -pix_fmt nv12 -s 1280x720 -r 30 -i in.nv12 \
       -c:v hevc_v4l2m2m -b:v 4M out.hevc
```

## 5. Transcode (compressed-to-compressed, both directions of both nodes)

```sh
ffmpeg -hide_banner -c:v h264_v4l2m2m -i a.h264 -c:v hevc_v4l2m2m -b:v 4M b.hevc
ffmpeg -hide_banner -c:v hevc_v4l2m2m -i b.hevc -c:v h264_v4l2m2m -b:v 4M c.h264
```

## 6. Multi-format discovery sweep (decoder)

```sh
for f in H264 HEVC VP90 AV01 MJPG MPG2 MPG4 H263 VP80; do
  echo "== $f"; v4l2-ctl -d /dev/videoX --list-formats-ext | grep -i "$f" || echo "  not advertised"
done
```

## 7. Backpressure / buffer-behavior checks

```sh
./fvm_qual m2m-encode /dev/videoY H264 1280 720 300 /tmp/long.h264   # >queue depth frames
v4l2-ctl -d /dev/videoY --get-fmt-video-output --get-fmt-video-capture
```

## 8. Drain / EOS / lifecycle

Covered by fvm_qual m2m-decode (DECODER_CMD STOP + EOS event) and by
close-cancels-session: interrupt a running encode (`timeout -s INT 5 ffmpeg ...`)
and verify the next open() gets a fresh session and full buffer set.

## Golden inputs already available

- the private native-02 evidence directory recorded by the primary (not part of the mergeable payload)
  carries the passed strict-hardware H264/HEVC 1280x720p30 clips and golden
  raw NV12 (see its RESULT.json for digests). Reuse those exact clips for the
  first decode comparisons.
