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
            command -v apt-get >/dev/null || exit 72
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tigervnc-standalone-server tigervnc-tools dbus-x11 openbox xfce4-panel xterm mousepad pcmanfm
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
                open:*)
                  gui_spec="${'$'}{gui_action#open:}"
                  gui_editor="${'$'}{gui_spec%%:*}"
                  case "${'$'}gui_editor" in mousepad|pcmanfm|xterm|libreoffice|gimp|inkscape|blender) ;; *) continue ;; esac
                  gui_file=${'$'}(printf '%s' "${'$'}{gui_spec#*:}" | base64 -d) || continue
                  if test -f "./${'$'}gui_file"; then "${'$'}gui_editor" "./${'$'}gui_file" > /dev/null 2>&1 &
                  else printf '%s\n' 'FLOE_FILE_UNAVAILABLE'; fi ;;
                stop) exit 0 ;;
                mousepad|pcmanfm|xterm|libreoffice|gimp|inkscape|blender)
                  if command -v "${'$'}gui_action" >/dev/null; then
                    "${'$'}gui_action" > /dev/null 2>&1 &
                  else printf '%s%s\n' 'FLOE_MISSING:' "${'$'}gui_action"; fi ;;
                install:mousepad|install:libreoffice|install:gimp|install:inkscape|install:blender)
                  gui_package="${'$'}{gui_action#install:}"
                  if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${'$'}gui_package"; then
                    printf '%s%s\n' 'FLOE_INSTALLED:' "${'$'}gui_package"
                  else printf '%s%s\n' 'FLOE_INSTALL_FAILED:' "${'$'}gui_package"; fi ;;
              esac
            done
        """.trimIndent()
        return "bash -c ${quote(script)}\n"
    }

    fun application(name: String, install: Boolean): ByteArray {
        require(name in applications)
        return ((if (install) "install:" else "") + name + "\n").toByteArray(Charsets.UTF_8)
    }
}
