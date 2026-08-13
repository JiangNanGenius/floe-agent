#!/bin/sh
set -eu

test -n "${FLOE_VNC_PASSWORD:-}"
mkdir -p /run/floe-vnc
x11vnc -storepasswd "$FLOE_VNC_PASSWORD" /run/floe-vnc/passwd
Xvfb :0 -screen 0 1920x1080x24 -nolisten tcp &
export DISPLAY=:0
fluxbox &
xterm -geometry 100x30+80+80 -title "Floe Agent M0 VNC" &
exec x11vnc -display :0 -rfbauth /run/floe-vnc/passwd -forever -shared -rfbport 5900 -noxdamage
