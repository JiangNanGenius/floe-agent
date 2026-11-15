#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Generate round-trip fixtures from the immutable native-02 evidence plus
# freshly encoded single/multi-frame samples, and embed the first coded frame
# of each into Sources/FloeLinuxVideoHost/FLVProbeSamples.m (probe data).
#
# usage: gen_fixtures.sh <fixtures_out_dir> <probe_samples_out.m>
# Requires: ffmpeg + ffprobe (homebrew). Never writes into native-02 evidence.
set -euo pipefail
OUT_DIR="$1"
PROBE_OUT="$2"
NATIVE02="${FLOE_NATIVE02_EVIDENCE:-}"
if [ -z "$NATIVE02" ]; then
  echo "FLOE_NATIVE02_EVIDENCE must point at the primary's native-02 fixture directory" >&2
  exit 2
fi
FFMPEG="/opt/homebrew/bin/ffmpeg"
FFPROBE="/opt/homebrew/bin/ffprobe"
mkdir -p "$OUT_DIR"

# --- native-02 Annex-B elementary streams + goldens (immutable inputs) ---
# AUD NALs are inserted (h264/hevc_metadata aud=1) so access-unit boundaries
# are unambiguous: a new AU starts at every AUD; NALs before the first AUD
# belong to AU 0. AUD carries no picture data, so the coded pixel content
# and the 30-frame NV12 golden comparisons are unchanged.
"$FFMPEG" -hide_banner -nostdin -loglevel error -y -i "$NATIVE02/h264.mp4" \
  -map 0:v -c copy -bsf:v "h264_mp4toannexb,h264_metadata=aud=1" "$OUT_DIR/h264-annexb.h264"
"$FFMPEG" -hide_banner -nostdin -loglevel error -y -i "$NATIVE02/hevc.mp4" \
  -map 0:v -c copy -bsf:v "hevc_mp4toannexb,hevc_metadata=aud=1" "$OUT_DIR/hevc-annexb.h265"
cp "$NATIVE02/h264-hardware.nv12" "$OUT_DIR/h264-golden.nv12"
cp "$NATIVE02/hevc-hardware.nv12" "$OUT_DIR/hevc-golden.nv12"

# --- freshly encoded small fixtures (single-frame except where noted) ---
"$FFMPEG" -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 4 \
  -c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1 -f ivf "$OUT_DIR/vp9.ivf" || echo "vp9 skipped"
"$FFMPEG" -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 4 \
  -c:v libaom-av1 -crf 45 -b:v 0 -cpu-used 8 -f ivf "$OUT_DIR/av1.ivf" || \
"$FFMPEG" -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 4 \
  -c:v libsvtav1 -crf 45 -preset 8 -f ivf "$OUT_DIR/av1.ivf" || echo "av1 skipped"
"$FFMPEG" -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 3 \
  -c:v mjpeg -q:v 4 "$OUT_DIR/mjpeg.mjpeg" || echo "mjpeg skipped"

# --- single-frame raw-packet fixtures via the data muxer ---
make_raw_fixture () {
  local name="$1"; shift
  local enc="$1"; shift
  local extra_args=("$@")
  local tmp="$OUT_DIR/.${name}.mov"
  if "$FFMPEG" -hide_banner -nostdin -loglevel error -y \
      -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 1 \
      -c:v "$enc" "${extra_args[@]}" "$tmp"; then
    "$FFMPEG" -hide_banner -nostdin -loglevel error -y -i "$tmp" \
      -map 0:v -c copy -f data "$OUT_DIR/${name}.bin"
    rm -f "$tmp"
  else
    echo "${name} skipped"
    rm -f "$tmp"
  fi
}
make_raw_fixture prores422 prores_ks -profile:v 2
make_raw_fixture prores4444 prores_ks -profile:v 4 -pix_fmt yuva444p10le
make_raw_fixture mpeg2 mpeg2video -q:v 5
make_raw_fixture h263 h263 -s 176x144
make_raw_fixture mpeg4 mpeg4 -q:v 5

# --- manifest with truthful coded dimensions ---
cat > "$OUT_DIR/fixtures.json" <<'EOF'
{
  "vp9.ivf":    {"width": 320, "height": 180, "packets": "ivf"},
  "av1.ivf":    {"width": 320, "height": 180, "packets": "ivf"},
  "mjpeg.mjpeg":{"width": 320, "height": 180, "packets": "jpeg-scans"},
  "prores422.bin": {"width": 320, "height": 180, "packets": "single"},
  "prores4444.bin": {"width": 320, "height": 180, "packets": "single"},
  "mpeg2.bin":  {"width": 320, "height": 180, "packets": "single"},
  "h263.bin":   {"width": 176, "height": 144, "packets": "single"},
  "mpeg4.bin":  {"width": 320, "height": 180, "packets": "single", "note": "requires esds; not used by tests"}
}
EOF

# --- VP9 software reference decode (pixel compare for host VP9 decode) ---
# Independent of VideoToolbox: plain ffmpeg software decode of the first
# coded frame to tight NV12, consumed by flv_test_roundtrip / flv_test_software_fallback.
if [ -f "$OUT_DIR/vp9.ivf" ]; then
  "$FFMPEG" -hide_banner -nostdin -loglevel error -y -hwaccel none -i "$OUT_DIR/vp9.ivf" \
    -frames:v 1 -an -pix_fmt nv12 -f rawvideo "$OUT_DIR/vp9-ref.nv12" || echo "vp9-ref skipped"
fi

# --- embed first frames into FLVProbeSamples.m ---
python3 - "$OUT_DIR" "$PROBE_OUT" "$FFMPEG" "$FFPROBE" <<'PYEOF'
import json, subprocess, sys
out_dir, probe_out, ffmpeg = sys.argv[1], sys.argv[2], sys.argv[3]
ffprobe_bin = sys.argv[4]
manifest = json.load(open(f"{out_dir}/fixtures.json"))

def run(*a):
    return subprocess.run(a, capture_output=True)

entries = []

def ivf_first_frame(path):
    data = open(path, "rb").read()
    if len(data) < 32 or data[:4] != b"DKIF":
        return None, 0, 0
    hdr = int.from_bytes(data[6:8], "little")
    w = int.from_bytes(data[12:14], "little")
    h = int.from_bytes(data[14:16], "little")
    off = hdr
    sz = int.from_bytes(data[off:off+4], "little")
    return data[off+12:off+12+sz], w, h

# h264/hevc: FIRST COMPLETE ACCESS UNIT from the annexb streams. The
# fixtures carry AUD NALs (h264/hevc_metadata aud=1), so the AU boundary is
# unambiguous: AU0 runs from the first AUD to the second AUD (NALs before
# the first AUD, e.g. an encoder-header SEI, belong to AU0). Without AUDs,
# fall back to capping at 8 NALUs.
def start_code_positions(data):
    positions = []
    i = 0
    while i + 3 < len(data):
        if data[i] == 0 and data[i+1] == 0 and data[i+2] == 1:
            positions.append(i)
            i += 3
        else:
            i += 1
    return positions

def nal_type(data, pos, codec):
    # first payload byte after the 3- or 4-byte start code
    p = pos + 3
    if p < len(data) and data[p] == 0:
        p += 1
    if p >= len(data):
        return -1
    if codec == "h264":
        return data[p] & 0x1F
    return (data[p] >> 1) & 0x3F

def is_aud(data, pos, codec):
    t = nal_type(data, pos, codec)
    return t == 9 if codec == "h264" else t == 35

def first_au_with_sps(path, codec):
    data = open(path, "rb").read()
    positions = start_code_positions(data)
    if not positions:
        return None
    first_aud = None
    second_aud = None
    for pos in positions:
        if is_aud(data, pos, codec):
            if first_aud is None:
                first_aud = pos
            else:
                second_aud = pos
                break
    if first_aud is not None:
        au = data[first_aud:second_aud] if second_aud is not None else data[first_aud:]
        return au
    # No AUD: legacy cap at 8 NALUs.
    nalus = []
    for idx, pos in enumerate(positions[:8]):
        end = positions[idx+1] if idx+1 < len(positions) else min(len(data), pos + 4096)
        nalus.append(data[pos:end])
    return b"".join(nalus)

import os
h264_au = first_au_with_sps(f"{out_dir}/h264-annexb.h264", "h264")
hevc_au = first_au_with_sps(f"{out_dir}/hevc-annexb.h265", "hevc")

def hexarr(b):
    if not b: return "{0}"
    lines = []
    for i in range(0, len(b), 16):
        lines.append("    " + ", ".join(f"0x{x:02x}" for x in b[i:i+16]))
    return "{\n" + ",\n".join(lines) + "\n  }"

# config records: build avcC/hvcC via small helper through ffmpeg-extracted SPS/PPS
def extract_ps_from_au(au, codec):
    # split nalus
    nals = []
    positions = []
    i = 0
    while i + 3 < len(au):
        if au[i] == 0 and au[i+1] == 0 and au[i+2] == 1:
            positions.append(i); i += 3
        else:
            i += 1
    for idx, pos in enumerate(positions):
        end = positions[idx+1] if idx+1 < len(positions) else len(au)
        while end > pos and au[end-1] == 0: end -= 1
        nals.append(au[pos+3:end])
    sps = pps = vps = None
    for n in nals:
        if not n: continue
        if codec == "h264":
            t = n[0] & 0x1F
            if t == 7: sps = n
            elif t == 8: pps = n
        else:
            t = (n[0] >> 1) & 0x3F
            if t == 33: sps = n
            elif t == 34: pps = n
            elif t == 32: vps = n
    return sps, pps, vps

def avcc(sps, pps):
    return bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE0 | 1]) + len(sps).to_bytes(2, "big") + sps + bytes([1]) + len(pps).to_bytes(2, "big") + pps

def hvcc(sps, pps, vps):
    body = bytes([1, 1, 0, 0, 0, 0]) + bytes(6) + bytes([0x78, 0xF0, 0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0x00, 0x00, 0x0F])
    arrs = []
    if vps: arrs.append((32, vps))
    arrs.append((33, sps)); arrs.append((34, pps))
    tail = bytes([len(arrs)])
    for t, n in arrs:
        tail += bytes([t, 0, 1]) + len(n).to_bytes(2, "big") + n
    return body + tail

entries_meta = []
if h264_au:
    sps, pps, _ = extract_ps_from_au(h264_au, "h264")
    if sps and pps:
        cfg = avcc(sps, pps)
        entries_meta.append(("FLV_H264", "FLV_NV12", 1280, 720, cfg, h264_au, "ffmpeg h264 (native-02 clip)"))
if hevc_au:
    sps, pps, vps = extract_ps_from_au(hevc_au, "hevc")
    if sps and pps:
        cfg = hvcc(sps, pps, vps)
        entries_meta.append(("FLV_HEVC", "FLV_NV12", 1280, 720, cfg, hevc_au, "ffmpeg hevc (native-02 clip)"))

# vp9/av1 from IVF
def ffprobe_stream(path):
    r = subprocess.run([ffprobe_bin,
                        "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "stream=profile,level,pix_fmt,color_range,color_primaries,color_trc,color_space",
                        "-of", "json", path], capture_output=True, text=True)
    try:
        streams = json.loads(r.stdout)["streams"]
        return streams[0] if streams else {}
    except Exception:
        return {}

def vpcc_from_stream(path):
    """12-byte VideoToolbox vpcC (mirrors Sources FLVBitstream flv_vpcc_build):
    version 1 + 3 flag bytes, profile, level (0 = Undefined), packed
    bit-depth/chroma/range byte, three colour bytes, u16 zero init size.
    Dimensions are NOT in the record (they belong to the CMFormatDescription).
    Every field comes from verified ffprobe metadata or the explicit
    "unknown" value — never invented."""
    st = ffprobe_stream(path)
    profile = 0  # all current fixtures are profile 0; VP9 IVF header has no profile
    level = st.get("level") or 0
    try:
        level = int(level)
    except (TypeError, ValueError):
        level = 0
    if level < 0 or level > 255:
        level = 0  # Undefined
    pix_fmt = st.get("pix_fmt", "")
    bit_depth = 10 if "10" in pix_fmt else 8
    subsampling = {"yuv420p": 1, "yuv422p": 2, "yuv444p": 3,
                   "yuv420p10le": 1, "yuv420p10be": 1}.get(pix_fmt, 1)
    full_range = 1 if st.get("color_range") == "pc" else 0
    def colour(key):
        v = st.get(key)
        if v in (None, "", "unknown"):
            return 2  # unspecified: explicit unknown, never invented
        try:
            return int(v)
        except (TypeError, ValueError):
            return 2
    return bytes([1, 0, 0, 0, profile & 0xFF, level & 0xFF,
                  ((bit_depth & 0x0F) << 4) | ((subsampling & 0x07) << 1) | full_range,
                  colour("color_primaries"), colour("color_trc"), colour("color_space"),
                  0, 0])

for file, codec, macro, cfgname in (("vp9.ivf", "FLV_VP9", None, "vpcc"), ("av1.ivf", "FLV_AV1", None, "av1c")):
    p = f"{out_dir}/{file}"
    if os.path.exists(p):
        frame, w, h = ivf_first_frame(p)
        if frame:
            cfg = b""
            if cfgname == "vpcc":
                cfg = vpcc_from_stream(p)
            else:
                cfg = bytes([0x81, (0 << 5) | 10, 0x0C, 0x00])
            entries_meta.append((macro or codec, "FLV_NV12", w, h, cfg, frame, f"ffmpeg {file.split('.')[0]}"))

# mjpeg first scan
mj = f"{out_dir}/mjpeg.mjpeg"
if os.path.exists(mj):
    data = open(mj, "rb").read()
    start = data.find(b"\xff\xd8")
    if start >= 0:
        end = data.find(b"\xff\xd9", start)
        if end > 0:
            frame = data[start:end+2]
            entries_meta.append(("FLV_MJPEG", "FLV_NV12", 320, 180, b"", frame, "ffmpeg mjpeg"))

# raw single-frame fixtures
for file, macro, w, h in (("prores422.bin", "FLV_PRORES422", 320, 180),
                          ("prores4444.bin", "FLV_PRORES4444", 320, 180),
                          ("mpeg2.bin", "FLV_MPEG2", 320, 180),
                          ("h263.bin", "FLV_H263", 176, 144)):
    p = f"{out_dir}/{file}"
    if os.path.exists(p):
        data = open(p, "rb").read()
        if data:
            entries_meta.append((macro, "FLV_NV12", w, h, b"", data, f"ffmpeg {file.split('.')[0]}"))

with open(probe_out, "w") as f:
    f.write("/* SPDX-License-Identifier: MPL-2.0 */\n")
    f.write("/* GENERATED by tests/gen_fixtures.sh -- one-frame coded probe samples.\n")
    f.write(" * Do not edit by hand. */\n")
    f.write('#include "floe_linux_video.h"\n')
    f.write('#import "FLVProbeSamples.h"\n\n')
    for i, (codec, pf, w, h, cfg, frame, gen) in enumerate(entries_meta):
        f.write(f"static const uint8_t flv_ps_cfg_{i}[] = {hexarr(cfg)};\n" if cfg else f"static const uint8_t flv_ps_cfg_{i}[1] = {{0}};\n")
        f.write(f"static const uint8_t flv_ps_frame_{i}[] = {hexarr(frame)};\n")
    f.write("\nconst FLVProbeSample flv_probe_samples[] = {\n")
    for i, (codec, pf, w, h, cfg, frame, gen) in enumerate(entries_meta):
        cfg_ptr = f"flv_ps_cfg_{i}" if cfg else "NULL"
        cfg_len = str(len(cfg)) if cfg else "0"
        f.write(f"    {{ {codec}, {pf}, {w}u, {h}u, {cfg_ptr}, {cfg_len}, flv_ps_frame_{i}, sizeof(flv_ps_frame_{i}), \"{gen}\" }},\n")
    f.write("};\n")
    f.write(f"const size_t flv_probe_samples_count = {len(entries_meta)};\n")
print(f"wrote {probe_out} with {len(entries_meta)} entries")
PYEOF

echo "fixtures generated in $OUT_DIR"
