#!/bin/sh
# Real guest regression: an encoder must finish successfully when writing to
# the project workspace, including the end-of-stream drain.
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
out=$1
if [ -e "$out" ]; then
    echo "output already exists: $out" >&2
    exit 2
fi
mkdir "$out"
python3 - "$out/input.nv12" <<'PY'
import sys
frame = bytes(i % 220 + 16 for i in range(160 * 96)) + bytes([128]) * (160 * 96 // 2)
with open(sys.argv[1], "wb") as output:
    output.write(frame * 3)
PY
floe-codec encode --codec h264 --input "$out/input.nv12" --output "$out/output.h264" \
    --width 160 --height 96 --limit 3 --backend v4l2 --json 2> "$out/codec.json"
test -s "$out/output.h264"
ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=codec_name,width,height,nb_read_frames -of json \
    "$out/output.h264" > "$out/ffprobe.json"
python3 - "$out/codec.json" "$out/ffprobe.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    codec = json.load(source)
with open(sys.argv[2]) as source:
    streams = json.load(source)["streams"]
assert codec["ok"] and codec["bytes_out"] > 0
assert len(streams) == 1
assert (streams[0]["codec_name"], streams[0]["width"], streams[0]["height"],
        int(streams[0]["nb_read_frames"])) == ("h264", 160, 96, 3)
print("PASS: V4L2 H.264 workspace output, exit status and frame count")
PY
