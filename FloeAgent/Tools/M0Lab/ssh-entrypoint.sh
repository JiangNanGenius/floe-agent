#!/bin/sh
set -eu

test -n "${FLOE_SSH_PASSWORD:-}"
printf '%s:%s\n' floe "$FLOE_SSH_PASSWORD" | chpasswd
ssh-keygen -A
exec /usr/sbin/sshd -D -e
