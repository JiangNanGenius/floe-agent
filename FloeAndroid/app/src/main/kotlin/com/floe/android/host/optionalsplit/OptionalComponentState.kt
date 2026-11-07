// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import android.content.Context
import android.content.Intent

/** App-owned install state for one optional signed split. The installed flag
 * is derived ONLY from a PackageManager read-back (split name present in the
 * package), never from a download or session callback. One shape serves every
 * optional preview component (Office today, CAD here). */
internal data class OptionalComponentState(
    val phase: String = "missing",
    val bytes: Long = 0,
    val totalBytes: Long = 0,
    val failure: String? = null,
    val pendingIntent: Intent? = null,
    val removable: Boolean = true,
    val installedBytes: Long = 0,
    val cachedBytes: Long = 0,
) {
    val working: Boolean get() = phase in setOf(
        "downloading", "cancelling", "clearing", "installing", "permission",
        "confirm", "play_confirm", "removing", "remove_pending")
}

/** Immutable identity of one optional split component. Channel backends
 * (Full/Play) are built from this spec alone, so a second component can never
 * drift into a parallel installer or permission framework. */
internal class OptionalComponentSpec(
    /** Dynamic-feature split name, validated by the system on install. */
    val module: String,
    /** SharedPreferences file that survives process death for one session. */
    val prefsName: String,
    /** App-private directory (under filesDir) that holds the staged artifact.
     * Fixed per component so an in-flight staged file survives app updates. */
    val stagingDir: String,
    /** Exact release-asset name the Full channel downloads. */
    val assetName: () -> String,
    /** Broadcast action that delivers the PackageInstaller session result
     * (Full channel only). */
    val resultAction: String,
    /** BroadcastReceiver class declared in the Full channel manifest; null on
     * Play, which delivers results through its session listener. */
    val resultReceiver: Class<out android.content.BroadcastReceiver>?,
    /** Foreground download service declared in the Full channel manifest;
     * null on Play, which downloads inside its own delivery session. */
    val downloadService: Class<out android.app.Service>?,
    /** Component-present probe used for EVERY installed-flag decision. */
    val installed: (Context) -> Boolean,
) {
    init {
        require(module.matches(Regex("[a-z][a-z0-9_]{1,40}"))) { "component_module_invalid" }
        require(prefsName.matches(Regex("[a-z0-9_]{1,64}"))) { "component_prefs_invalid" }
        require(stagingDir !in setOf(".", "..") && stagingDir.matches(Regex("[A-Za-z0-9_.-]{1,64}"))) { "component_staging_invalid" }
        require(resultAction.startsWith("com.floe.") && resultAction.length <= 120) {
            "component_action_invalid"
        }
    }
}

internal interface OptionalComponentBackend {
    fun install()
    // Play owns its download cache; only Full has App-owned staged files.
    fun cacheBytes(): Long = 0
    fun clearCache() = Unit
    fun uninstall()
    fun cancel()
    fun onForeground(activity: android.app.Activity)
    fun onInstallResult(intent: Intent) = Unit
    fun confirm(activity: android.app.Activity) { onForeground(activity) }
}
