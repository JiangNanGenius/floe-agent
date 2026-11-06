// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

/** Fixed guest-side launcher. All commands execute in the existing resolved Linux PTY. */
internal object LinuxDesktopCommands {
    val applications = setOf("mousepad", "pcmanfm", "xterm", "libreoffice", "gimp", "inkscape", "blender")
    private fun quote(value: String) = "'" + value.replace("'", "'\"'\"'") + "'"

    fun launch(nonce: String, display: Int, width: Int, height: Int, install: Boolean, desktop: Boolean): String {
        require(nonce.matches(Regex("[a-f0-9]{32}")) && display in 10..209)
        require(width in 640..2560 && height in 480..1600)
        val installCommand = if (install) """
            gui_missing=0
            for gui_tool in Xtigervnc vncpasswd dbus-run-session openbox ${if (desktop) "xfce4-panel" else ""}; do
              command -v "${'$'}gui_tool" >/dev/null 2>&1 || gui_missing=1
            done
            if test "${'$'}gui_missing" = 1; then
              command -v apt-get >/dev/null || exit 72
              apt-get update
              DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tigervnc-standalone-server tigervnc-tools dbus-x11 openbox xfce4-panel xterm mousepad pcmanfm
            fi
        """.trimIndent() else ""
        val script = """
            set -eu
            umask 077
            $installCommand
            command -v Xtigervnc >/dev/null || exit 73
            command -v vncpasswd >/dev/null || exit 74
            gui_dir="${'$'}{TMPDIR:-/tmp}/floe-gui-$nonce"
            mkdir -p "${'$'}gui_dir"
            cleanup() {
              stty echo 2>/dev/null || true
              test -z "${'$'}{gui_wm:-}" || kill "${'$'}gui_wm" 2>/dev/null || true
              test -z "${'$'}{gui_vnc:-}" || kill "${'$'}gui_vnc" 2>/dev/null || true
              rm -f -- "${'$'}gui_dir/passwd"
              rmdir -- "${'$'}gui_dir" 2>/dev/null || true
            }
            trap cleanup EXIT HUP INT TERM
            stty -echo
            printf '%s%s\n' 'FLOE_READ:' '$nonce'
            IFS= read -r gui_secret
            printf '%s' "${'$'}gui_secret" | vncpasswd -f > "${'$'}gui_dir/passwd"
            unset gui_secret
            stty echo
            export DISPLAY=:$display
            export XDG_RUNTIME_DIR="${'$'}gui_dir"
            ${if (!desktop) """
            printf '%s' '<openbox_config xmlns="http://openbox.org/3.4/rc"><applications><application class="*"><decor>no</decor><fullscreen>yes</fullscreen></application></applications></openbox_config>' > "${'$'}gui_dir/rc.xml"
            """.trimIndent() else ""}
            Xtigervnc :$display -localhost yes -SecurityTypes VncAuth -rfbauth "${'$'}gui_dir/passwd" -rfbport ${5900 + display} -geometry ${width}x$height -depth 24 -AlwaysShared > "${'$'}gui_dir/server.log" 2>&1 &
            gui_vnc=${'$'}!
            sleep 1
            kill -0 "${'$'}gui_vnc"
            ${if (desktop) "dbus-run-session -- sh -c 'openbox & xfce4-panel & wait'" else "dbus-run-session -- openbox --config-file \"${'$'}gui_dir/rc.xml\""} > "${'$'}gui_dir/desktop.log" 2>&1 &
            gui_wm=${'$'}!
            printf '%s%s\n' 'FLOE_READY:' '$nonce'
            while IFS= read -r gui_action; do
              case "${'$'}gui_action" in
                edit:*)
                  gui_spec="${'$'}{gui_action#edit:}"
                  gui_editor="${'$'}{gui_spec%%:*}"; gui_spec="${'$'}{gui_spec#*:}"
                  gui_source="${'$'}{gui_spec%%:*}"; gui_spec="${'$'}{gui_spec#*:}"
                  gui_target="${'$'}{gui_spec%%:*}"; gui_ack="${'$'}{gui_spec#*:}"
                  case "${'$'}gui_editor" in mousepad|pcmanfm|xterm|libreoffice|gimp|inkscape|blender) ;; *) continue ;; esac
                  gui_source=${'$'}(printf '%s' "${'$'}gui_source" | base64 -d) || continue
                  gui_target=${'$'}(printf '%s' "${'$'}gui_target" | base64 -d) || continue
                  if test ! -e "./${'$'}gui_target"; then
                    mkdir -p -- "./${'$'}{gui_target%/*}"
                    if ! cp -- "./${'$'}gui_source" "./${'$'}gui_target"; then continue; fi
                    printf '%s%s\n' 'FLOE_EDIT_CREATED:' "${'$'}gui_ack"
                  else printf '%s%s\n' 'FLOE_EDIT_REUSED:' "${'$'}gui_ack"; fi
                  ;;
                open:*)
                  gui_spec="${'$'}{gui_action#open:}"
                  gui_editor="${'$'}{gui_spec%%:*}"
                  case "${'$'}gui_editor" in mousepad|pcmanfm|xterm|libreoffice|gimp|inkscape|blender) ;; *) continue ;; esac
                  gui_file=${'$'}(printf '%s' "${'$'}{gui_spec#*:}" | base64 -d) || continue
                  if test -f "./${'$'}gui_file"; then "${'$'}gui_editor" "./${'$'}gui_file" > /dev/null 2>&1 &
                  else printf '%s\n' 'FLOE_FILE_UNAVAILABLE'; fi ;;
                inventory:*)
                  gui_query="${'$'}{gui_action#inventory:}"
                  for gui_package in mousepad pcmanfm xterm libreoffice gimp inkscape blender; do
                    gui_sizes=${'$'}(dpkg-query -W -f='${'$'}{db:Status-Abbrev} ${'$'}{Installed-Size}\n' "${'$'}gui_package*" 2>/dev/null || true)
                    gui_bytes=${'$'}(printf '%s\n' "${'$'}gui_sizes" | awk '${'$'}1 == "ii" {s += ${'$'}2; found=1} END {if(found) printf "%.0f", s*1024; else printf "missing"}')
                    printf 'FLOE_SOFTWARE:%s:%s:%s\n' "${'$'}gui_query" "${'$'}gui_package" "${'$'}gui_bytes"
                  done ;;
                uninstall:mousepad:*|uninstall:pcmanfm:*|uninstall:xterm:*|uninstall:libreoffice:*|uninstall:gimp:*|uninstall:inkscape:*|uninstall:blender:*)
                  gui_spec="${'$'}{gui_action#uninstall:}"; gui_package="${'$'}{gui_spec%%:*}"; gui_ack="${'$'}{gui_spec#*:}"
                  mapfile -t gui_packages < <(dpkg-query -W -f='${'$'}{db:Status-Abbrev} ${'$'}{binary:Package}\n' "${'$'}gui_package*" 2>/dev/null | awk '${'$'}1 == "ii" {print ${'$'}2}')
                  if test "${'$'}{#gui_packages[@]}" = 0 || apt-get remove -y -- "${'$'}{gui_packages[@]}"; then
                    printf '%s%s\n' 'FLOE_REMOVED:' "${'$'}gui_ack"
                  else printf '%s%s\n' 'FLOE_REMOVE_FAILED:' "${'$'}gui_ack"; fi ;;
                clean-cache:*)
                  gui_ack="${'$'}{gui_action#clean-cache:}"
                  if apt-get clean; then printf '%s%s\n' 'FLOE_CACHE_CLEANED:' "${'$'}gui_ack"; else printf '%s%s\n' 'FLOE_CACHE_FAILED:' "${'$'}gui_ack"; fi ;;
                stop) exit 0 ;;
                mousepad|pcmanfm|xterm|libreoffice|gimp|inkscape|blender)
                  if command -v "${'$'}gui_action" >/dev/null; then
                    "${'$'}gui_action" > /dev/null 2>&1 &
                  else printf '%s%s\n' 'FLOE_MISSING:' "${'$'}gui_action"; fi ;;
                install:mousepad:*|install:pcmanfm:*|install:xterm:*|install:libreoffice:*|install:gimp:*|install:inkscape:*|install:blender:*)
                  gui_spec="${'$'}{gui_action#install:}"; gui_package="${'$'}{gui_spec%%:*}"; gui_ack="${'$'}{gui_spec#*:}"
                  if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${'$'}gui_package"; then
                    printf '%s%s\n' 'FLOE_INSTALLED:' "${'$'}gui_ack"
                  else printf '%s%s\n' 'FLOE_INSTALL_FAILED:' "${'$'}gui_ack"; fi ;;
              esac
            done
        """.trimIndent()
        return "bash -c ${quote(script)}\n"
    }

    fun application(name: String, install: Boolean, nonce: String? = null): ByteArray {
        require(name in applications)
        if (install) require(nonce?.matches(Regex("[a-f0-9]{32}")) == true)
        return (if (install) "install:$name:$nonce\n" else "$name\n").toByteArray(Charsets.UTF_8)
    }
}
