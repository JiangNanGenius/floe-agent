#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Master component-test runner (macOS). Assumes fixtures already generated.
# usage: run_tests.sh <work_dir>
# Writes binaries, decoded outputs and RESULT.json under <work_dir>.
#
# Verification policy (repaired 2026-11-11, native stage2):
#  - Every child build/test failure, every ffprobe/ffmpeg failure and every
#    missing expected output marks the overall run FAILED and yields a
#    nonzero exit. RESULT.json "status" reflects reality ("passed" only when
#    every recorded check passed); it is never unconditionally "complete".
#  - ffprobe must count exactly 30 frames in each encoded stream.
#  - FFmpeg stderr is preserved in evidence logs, never discarded.
#  - No quality threshold is invented: PSNR is measured and reported.
set -uo pipefail
WORK="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVID="${WORK}/evidence"
FIX="${WORK}/fixtures"
BIN="${WORK}/bin"
mkdir -p "$EVID" "$BIN"
FFMPEG="/opt/homebrew/bin/ffmpeg"
FFPROBE="/opt/homebrew/bin/ffprobe"
CLANG="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

result=""
overall="passed"
record_result () {
  local name="$1" status="$2"
  result=$(printf '%s\n  "%s": "%s",' "$result" "$name" "$status")
  if [ "$status" != "passed" ]; then overall="failed"; fi
}

echo "=== build ==="
ok=1
"$ROOT/tests/build_macos.sh" flv_test_capabilities "$BIN/flv_test_capabilities" || { record_result build_capabilities failed; ok=0; }
"$ROOT/tests/build_macos.sh" flv_test_malformed_limits "$BIN/flv_test_malformed_limits" || { record_result build_malformed failed; ok=0; }
"$ROOT/tests/build_macos.sh" flv_test_cancel_ownership "$BIN/flv_test_cancel_ownership" || { record_result build_cancel failed; ok=0; }
"$ROOT/tests/build_macos.sh" flv_test_roundtrip "$BIN/flv_test_roundtrip" || { record_result build_roundtrip failed; ok=0; }
"$ROOT/tests/build_macos.sh" flv_test_software_fallback "$BIN/flv_test_software_fallback" || { record_result build_software_fallback failed; ok=0; }
"$ROOT/tests/build_macos.sh" flv_test_prores_encode "$BIN/flv_test_prores_encode" || { record_result build_prores_encode failed; ok=0; }
"$ROOT/tests/build_macos.sh" flv_test_imageio_jpeg "$BIN/flv_test_imageio_jpeg" || { record_result build_imageio_jpeg failed; ok=0; }
[ "$ok" = 1 ] || { printf '{\n  "generated_at": "%s",\n  "status": "build-failed"\n}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$EVID/RESULT.json"; exit 1; }
record_result build passed

echo "=== capabilities ==="
if "$ROOT/tests/run_bounded.sh" 300 "$BIN/flv_test_capabilities" > "$EVID/capabilities.json" 2> "$EVID/capabilities.stderr"; then
  record_result capabilities passed
else
  record_result capabilities failed
fi

echo "=== malformed/limits ==="
if "$ROOT/tests/run_bounded.sh" 300 "$BIN/flv_test_malformed_limits" > "$EVID/malformed.json" 2> "$EVID/malformed.stderr"; then
  record_result malformed_limits passed
else
  record_result malformed_limits failed
fi

echo "=== cancel/ownership ==="
if "$ROOT/tests/run_bounded.sh" 300 "$BIN/flv_test_cancel_ownership" "$FIX/h264-annexb.h264" > "$EVID/cancel.json" 2> "$EVID/cancel.stderr"; then
  record_result cancel_ownership passed
else
  record_result cancel_ownership failed
fi

echo "=== roundtrip ==="
if "$ROOT/tests/run_bounded.sh" 900 "$BIN/flv_test_roundtrip" "$FIX" "$EVID" > "$EVID/roundtrip.json" 2> "$EVID/roundtrip.stderr"; then
  record_result roundtrip passed
else
  record_result roundtrip failed
fi

echo "=== software fallback / strict hardware rejection ==="
if "$ROOT/tests/run_bounded.sh" 600 "$BIN/flv_test_software_fallback" > "$EVID/software_fallback.json" 2> "$EVID/software_fallback.stderr"; then
  record_result software_fallback passed
else
  record_result software_fallback failed
fi

echo "=== ProRes 422/4444 public-VT encode + own decode ==="
if "$ROOT/tests/run_bounded.sh" 600 "$BIN/flv_test_prores_encode" > "$EVID/prores_encode.json" 2> "$EVID/prores_encode.stderr"; then
  record_result prores_encode passed
else
  record_result prores_encode failed
fi

echo "=== MJPEG public-ImageIO fallback ==="
if "$ROOT/tests/run_bounded.sh" 300 "$BIN/flv_test_imageio_jpeg" > "$EVID/imageio_jpeg.json" 2> "$EVID/imageio_jpeg.stderr"; then
  record_result imageio_jpeg passed
else
  record_result imageio_jpeg failed
fi

echo "=== external stream verification (ffprobe/ffmpeg) ==="
EXTERR="$EVID/ext-verify.stderr"
: > "$EXTERR"

# ext_verify <stream> : prints frame count; returns nonzero on ffprobe failure.
ext_verify () {
  local stream="$1"
  local count
  if ! count=$("$FFPROBE" -v error -count_frames -show_entries stream=nb_read_frames \
      -of default=noprint_wrappers=1:nokey=1 "$stream" 2>>"$EXTERR" | head -1); then
    return 1
  fi
  if [ -z "$count" ]; then return 1; fi
  echo "$count"
}

EXPECT_FRAMES=30
H264F=$(ext_verify "$EVID/h264-ours.h264") || H264F="failed"
H265F=$(ext_verify "$EVID/hevc-ours.h265") || H265F="failed"
record_result "h264_ours_ffprobe_frames" "$H264F"
record_result "hevc_ours_ffprobe_frames" "$H265F"
if [ "$H264F" != "$EXPECT_FRAMES" ]; then
  record_result h264_ours_framecount_check failed
else
  record_result h264_ours_framecount_check passed
fi
if [ "$H265F" != "$EXPECT_FRAMES" ]; then
  record_result hevc_ours_framecount_check failed
else
  record_result hevc_ours_framecount_check passed
fi

# independent software decode of our encoder output vs our decoder output
xdecode () {
  local stream="$1" ours="$2" ffmpeg_out="$3" name="$4"
  if [ ! -f "$stream" ]; then
    record_result "$name" "failed-missing-stream"
    return
  fi
  if ! "$FFMPEG" -hide_banner -nostdin -loglevel error -y -hwaccel none -threads 2 \
      -i "$stream" -an -fps_mode passthrough -pix_fmt nv12 -f rawvideo \
      "$ffmpeg_out" 2>>"$EXTERR"; then
    record_result "$name" "failed-ffmpeg-decode"
    return
  fi
  if [ ! -f "$ffmpeg_out" ]; then
    record_result "$name" "failed-no-ffmpeg-output"
    return
  fi
  if [ ! -f "$ours" ]; then
    record_result "$name" "failed-missing-ours"
    return
  fi
  if cmp -s "$ffmpeg_out" "$ours"; then
    record_result "$name" passed
  else
    record_result "$name" "mismatch"
  fi
}
xdecode "$EVID/h264-ours.h264" "$EVID/h264-ours-decoded.nv12" "$EVID/h264-ours-ffmpeg.nv12" h264_ours_xdecode_match
xdecode "$EVID/hevc-ours.h265" "$EVID/hevc-ours-decoded.nv12" "$EVID/hevc-ours-ffmpeg.nv12" hevc_ours_xdecode_match

# encode quality vs source (PSNR via ffmpeg); measured and reported only.
psnr_of () {
  local golden="$1" stream="$2" name="$3"
  if [ ! -f "$golden" ] || [ ! -f "$stream" ]; then
    record_result "$name" "unavailable-missing-input"
    return
  fi
  local psnr
  psnr=$("$FFMPEG" -hide_banner -nostdin -loglevel info -y \
    -f rawvideo -pix_fmt nv12 -s 1280x720 -i "$golden" \
    -i "$stream" -lavfi psnr -f null - 2>>"$EXTERR" | grep -E "average:[0-9.inf]+" | tail -1 || true)
  if [ -z "$psnr" ]; then
    record_result "$name" "unavailable"
  else
    record_result "$name" "$psnr"
  fi
}
psnr_of "$FIX/h264-golden.nv12" "$EVID/h264-ours.h264" h264_encode_psnr
psnr_of "$FIX/hevc-golden.nv12" "$EVID/hevc-ours.h265" hevc_encode_psnr

# hashes of artifacts
{
  echo "{"
  echo '  "generated_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'
  echo "$result"
  echo "  \"status\": \"$overall\""
  echo "}"
} > "$EVID/RESULT.json"
cat "$EVID/RESULT.json"
if [ "$overall" != "passed" ]; then
  exit 1
fi
exit 0
