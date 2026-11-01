// SPDX-License-Identifier: Apache-2.0
// Floe-authored command builders for the pinned native starter. The starter
// command is the only way Floe asks a shell/root context to launch the
// embedded server; every interpolated value is strictly validated and shell
// quoted, and no model-authored command text is accepted.
package moe.shizuku.starter

object StarterCommand {

    const val STARTER_EXECUTABLE = "libfloe_starter.so"
    const val ADB_PROCESS_NAME = "floe_adb_server"
    const val ROOT_PROCESS_NAME = "floe_root_server"
    const val ADB_MODE = "adb"
    const val ROOT_MODE = "root"

    private val PACKAGE = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")
    private val CLASS = Regex("^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$")
    private val HEX_64 = Regex("^[0-9a-f]{64}$")
    private val HEX_32 = Regex("^[0-9a-f]{32,64}$")

    data class Launch(
        val command: String,
        val processName: String,
        val mode: String,
    )

    /**
     * Command for the embedded ADB launcher. [replacePid] is supplied only
     * after the App's binder describe() proved the old server is the same
     * package/signing/protocol/ADB mode with server UID 2000 and that exact
     * PID; the native starter rechecks the PID's shell UID and current nice
     * name before killing only that PID. It never scans for a process name.
     */
    fun adbLaunch(
        nativeLibraryDir: String,
        apkPath: String,
        packageName: String,
        token: String,
        callerUid: Int,
        signingSha256: String,
        appVersionCode: Long,
        serverClass: String,
        replacePid: Int? = null,
    ): Launch {
        requireAbsolutePath(nativeLibraryDir, "nativeLibraryDir")
        requireAbsolutePath(apkPath, "apkPath")
        require(PACKAGE.matches(packageName)) { "invalid package" }
        require(HEX_64.matches(token)) { "invalid launch token" }
        require(callerUid in 1..99_999) { "invalid caller uid" }
        require(HEX_64.matches(signingSha256)) { "invalid signing digest" }
        require(appVersionCode > 0) { "invalid app version" }
        require(CLASS.matches(serverClass)) { "invalid server class" }
        if (replacePid != null) {
            // Only the exact PID the App verified through binder describe()
            // may be replaced. PID 0/1 and self are never valid targets.
            require(replacePid in 2..1_000_000_000) { "invalid replace pid" }
        }

        val executable = "$nativeLibraryDir/$STARTER_EXECUTABLE"
        requireAbsolutePath(executable, "starter")
        val command = buildString {
            append(quote(executable))
            append(" --apk=").append(quote(apkPath))
            append(" --package=").append(quote(packageName))
            append(" --token=").append(quote(token))
            append(" --caller-uid=").append(callerUid)
            append(" --signing-sha256=").append(quote(signingSha256))
            append(" --app-version=").append(appVersionCode)
            append(" --mode=").append(ADB_MODE)
            append(" --server-class=").append(quote(serverClass))
            append(" --process-name=").append(quote(ADB_PROCESS_NAME))
            if (replacePid != null) append(" --replace-pid=").append(replacePid)
        }
        return Launch(command, ADB_PROCESS_NAME, ADB_MODE)
    }

    /**
     * Root backend launch. This is executed by the already-granted libsu shell;
     * it never grants root by itself and must only be called after [uid == 0]
     * has been observed through the same shell.
     */
    fun rootLaunch(
        apkPath: String,
        packageName: String,
        token: String,
        callerUid: Int,
        signingSha256: String,
        appVersionCode: Long,
        serverClass: String,
    ): Launch {
        requireAbsolutePath(apkPath, "apkPath")
        require(PACKAGE.matches(packageName)) { "invalid package" }
        require(HEX_32.matches(token)) { "invalid launch token" }
        require(callerUid in 1..99_999) { "invalid caller uid" }
        require(HEX_64.matches(signingSha256)) { "invalid signing digest" }
        require(appVersionCode > 0) { "invalid app version" }
        require(CLASS.matches(serverClass)) { "invalid server class" }

        val args = listOf(
            "/system/bin/app_process",
            "-Djava.class.path=$apkPath",
            "-Dshizuku.library.path=${apkPath.substringBeforeLast('/')}/lib/arm64",
            "/system/bin",
            "--nice-name=$ROOT_PROCESS_NAME",
            serverClass,
            "--mode=$ROOT_MODE",
            "--apk=$apkPath",
            "--package=$packageName",
            "--token=$token",
            "--caller-uid=$callerUid",
            "--signing-sha256=$signingSha256",
            "--app-version=$appVersionCode",
        )
        val command = "CLASSPATH=${quote(apkPath)} " + args.joinToString(" ") { quote(it) }
        return Launch(command, ROOT_PROCESS_NAME, ROOT_MODE)
    }

    /** Command shown to the user for the Android 9/10 PC USB bootstrap path. */
    fun usbBootstrapCommand(adbLaunch: Launch): String = "adb shell " + quote(adbLaunch.command)

    /** Small host-side script for the same bootstrap; it contains no secret. */
    fun usbBootstrapScript(adbLaunch: Launch): String = buildString {
        append("#!/bin/sh\n")
        append("# Floe embedded system bootstrap (run on the PC with adb, device connected).\n")
        append("set -eu\n")
        append("exec adb shell ").append(quote(adbLaunch.command)).append("\n")
    }

    /** Fixed `pm path` fallback used by the native starter; never user supplied. */
    fun packagePathQuery(packageName: String): String {
        require(PACKAGE.matches(packageName)) { "invalid package" }
        return quote("/system/bin/pm") + " path " + quote(packageName)
    }

    fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    private fun requireAbsolutePath(value: String, label: String) {
        require(value.startsWith("/")) { "$label must be absolute" }
        require(value.length <= 4096) { "$label too long" }
        require(value.none { it == '\u0000' || it == '\n' || it == '\r' }) { "$label invalid" }
    }
}
