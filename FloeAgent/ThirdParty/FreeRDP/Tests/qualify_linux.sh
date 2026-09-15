#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root="${1:?dedicated absolute CI scratch directory required}"
script_root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$root"
python3 - "$script_root/../runtime.lock.json" "$root" <<'PY'
import hashlib,json,sys,tarfile,urllib.request
from pathlib import Path
lock=json.loads(Path(sys.argv[1]).read_text());root=Path(sys.argv[2])
data=urllib.request.urlopen(lock['source'],timeout=90).read()
assert hashlib.sha256(data).hexdigest()==lock['sha256']
archive=root/'source.tar.gz';archive.write_bytes(data)
with tarfile.open(archive) as tar:tar.extractall(root,filter='data')
PY
cmake -S "$root/freerdp-3.31.1" -B "$root/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_SHARED_LIBS=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=OFF \
  -DWITH_SERVER=OFF -DWITH_CHANNELS=OFF -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF \
  -DWITH_FFMPEG=OFF -DWITH_OPENH264=OFF -DWITH_CJSON=OFF -DWITH_AAD=OFF \
  -DWITH_JPEG=OFF -DWITH_WEBP=OFF -DWITH_PNG=OFF -DWITH_URIPARSER=OFF \
  -DWITH_ALSA=OFF -DWITH_PULSE=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_LIBUSB=OFF \
  -DWITH_FUSE=OFF -DWITH_KRB5=OFF -DWITH_SWSCALE=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF
cmake --build "$root/build" --target freerdp --parallel 2
cc -shared -fPIC -std=c11 -Wall -Wextra -Werror -pthread \
  -I "$script_root/../Bridge/include" -I "$root/freerdp-3.31.1/include" -I "$root/build/include" \
  -I "$root/freerdp-3.31.1/winpr/include" -I "$root/build/winpr/include" \
  "$script_root/../Bridge/FloeRDP.c" -L "$root/build/libfreerdp" -lfreerdp3 \
  -L "$root/build/winpr/libwinpr" -lwinpr3 -o "$root/libFloeRDP.so"
export LD_LIBRARY_PATH="$root/build/libfreerdp:$root/build/winpr/libwinpr"
export DISPLAY=:97
export FLOE_RDP_FIXTURE_EVENTS="$root/input-events.txt"
# These credentials exist only in this ephemeral job. Never retain them as artifacts.
export FLOE_RDP_FIXTURE_PASSWORD="$(openssl rand -hex 4)"
echo "::add-mask::$FLOE_RDP_FIXTURE_PASSWORD"
printf '%s\n' "$FLOE_RDP_FIXTURE_PASSWORD" > "$root/vnc-password.txt"
chmod 600 "$root/vnc-password.txt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$root/key.pem" -out "$root/certificate.pem" \
  -days 1 -subj '/CN=localhost' -addext 'subjectAltName=IP:127.0.0.1' > "$root/certificate-build.log" 2>&1
chmod 600 "$root/key.pem"
cat > "$root/xrdp.ini" <<EOF
[Globals]
ini_version=1
fork=true
port=tcp://127.0.0.1:3390
security_layer=tls
crypt_level=high
certificate=$root/certificate.pem
key_file=$root/key.pem
ssl_protocols=TLSv1.2,TLSv1.3
autorun=FloeFixture
allow_channels=false
allow_multimon=false
max_bpp=32
use_fastpath=both
[Logging]
LogFile=$root/xrdp.log
LogLevel=INFO
EnableSyslog=false
[FloeFixture]
name=FloeFixture
lib=libvnc.so
ip=127.0.0.1
port=5997
username=na
password=ask
EOF
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -f "$root/key.pem" "$root/vnc-password.txt"
}
trap cleanup EXIT
Xvfb :97 -screen 0 800x600x24 -nolisten tcp > "$root/xvfb.log" 2>&1 & pids+=("$!")
for attempt in {1..50}; do if xdpyinfo > /dev/null 2>&1; then break; fi; sleep .1; done
python3 "$script_root/desktop.py" > "$root/desktop.log" 2>&1 & pids+=("$!")
x11vnc -display :97 -rfbport 5997 -localhost -forever -shared -passwdfile "$root/vnc-password.txt" \
  -noipv6 -noxdamage > "$root/vnc.log" 2>&1 & pids+=("$!")
/usr/sbin/xrdp --nodaemon --config "$root/xrdp.ini" > "$root/xrdp-console.log" 2>&1 & pids+=("$!")
python3 - <<'PY'
import socket,time
for port in (3390,5997):
    for attempt in range(100):
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=.2):pass
            break
        except OSError:time.sleep(.1)
    else:raise RuntimeError('Fixture server did not start')
PY
WLOG_LEVEL=WARN timeout 120 python3 "$script_root/loopback.py" "$root"
