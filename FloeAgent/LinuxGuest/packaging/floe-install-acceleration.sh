#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# stdin is the base64 package from the app. This runs inside one project guest.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# dpkg-deb needs Linux ownership semantics for its temporary control files.
# The environment's ordinary package cache may be a host-backed share.
TMPDIR=/tmp
export PATH TMPDIR
if [ "$(uname -s)" != Linux ] || ! command -v dpkg >/dev/null || [ "$(dpkg --print-architecture)" != arm64 ]; then
    echo 'The offline package needs a Debian arm64 Linux environment.' >&2
    exit 2
fi
if [ "$(id -u)" != 0 ]; then
    echo 'Installing tools requires the package manager in this Linux environment.' >&2
    exit 2
fi
umask 077
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 1' HUP INT TERM
package="$stage/tools.deb"
base64 -d > "$package"
printf '%s  %s\n' "$1" "$package" | sha256sum --check --status
name=floe-acceleration-tools
[ "$(dpkg-deb -f "$package" Package)" = "$name" ]
[ "$(dpkg-deb -f "$package" Architecture)" = arm64 ]
version=$(dpkg-deb -f "$package" Version)
installed=$(dpkg-query -W -f='${Status}' "$name" 2>/dev/null || :)
if [ "$installed" = 'install ok installed' ]; then
    current=$(dpkg-query -W -f='${Version}' "$name")
    if dpkg --compare-versions "$current" gt "$version"; then
        echo "A newer version ($current) is already installed."
        exit 0
    fi
    dpkg-deb --ctrl-tarfile "$package" | tar -xOf - ./md5sums > "$stage/checksums"
    if [ "$current" = "$version" ] && (cd / && md5sum --status -c "$stage/checksums"); then
        echo "Acceleration tools $version are ready."
        exit 0
    fi
fi
dpkg --install "$package"
[ "$(dpkg-query -W -f='${Status}' "$name")" = 'install ok installed' ]
PATH=/usr/local/sbin:/usr/local/bin:$PATH /usr/local/bin/floe-accel status --json
