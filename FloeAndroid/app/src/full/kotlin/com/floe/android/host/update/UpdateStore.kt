// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.content.Context

/**
 * Persistent updater preferences. Ownership follows the existing App-local
 * preference pattern (`FloeThemeStore`): one private SharedPreferences file
 * owned by this feature, no second settings domain and no native-runtime
 * settings write. The PERSONALIZATION "automatic" preference in
 * SettingsHostPages is a different (agent personalization) setting and is
 * deliberately not reused here.
 */
internal interface UpdateStore {
    var autoCheckEnabled: Boolean
    var lastCheckAtMillis: Long
    var dismissedVersion: String?
    /** Serialized [DownloadMeta] of an incomplete (or just completed) download. */
    var pendingDownloadJson: String?
    /** Serialized [PendingInstall] awaiting system/install reconciliation. */
    var pendingInstallJson: String?
}

internal class SharedPrefsUpdateStore(context: Context) : UpdateStore {
    private val prefs = context.applicationContext
        .getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override var autoCheckEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTO_CHECK, true)
        set(value) {
            prefs.edit().putBoolean(KEY_AUTO_CHECK, value).apply()
        }

    override var lastCheckAtMillis: Long
        get() = prefs.getLong(KEY_LAST_CHECK, 0L)
        set(value) {
            prefs.edit().putLong(KEY_LAST_CHECK, value).apply()
        }

    override var dismissedVersion: String?
        get() = prefs.getString(KEY_DISMISSED_VERSION, null)
        set(value) {
            prefs.edit().putString(KEY_DISMISSED_VERSION, value).apply()
        }

    override var pendingDownloadJson: String?
        get() = prefs.getString(KEY_PENDING_DOWNLOAD, null)
        set(value) {
            prefs.edit().putString(KEY_PENDING_DOWNLOAD, value).apply()
        }

    override var pendingInstallJson: String?
        get() = prefs.getString(KEY_PENDING_INSTALL, null)
        set(value) {
            prefs.edit().putString(KEY_PENDING_INSTALL, value).apply()
        }

    private companion object {
        const val FILE = "floe_app_update"
        const val KEY_AUTO_CHECK = "auto_check_enabled"
        const val KEY_LAST_CHECK = "last_check_at"
        const val KEY_DISMISSED_VERSION = "dismissed_version"
        const val KEY_PENDING_DOWNLOAD = "pending_download"
        const val KEY_PENDING_INSTALL = "pending_install"
    }
}

/** Closed updater configuration: one known repository, one Full ARM64 channel. */
internal object UpdateConfig {
    const val REPOSITORY_OWNER = "JiangNanGenius"
    const val REPOSITORY_NAME = "floe-agent"
    const val STAGING_DIRECTORY = "app-update/staging"
    /** Automatic foreground/startup checks at most once per window. */
    const val AUTO_CHECK_INTERVAL_MS = 6L * 60L * 60L * 1000L
    /** Free space headroom required before staging an APK. */
    const val DISK_HEADROOM_BYTES = 64L * 1024L * 1024L
    /** Bounded wait for owned work to settle before an explicit force install. */
    const val QUIESCENCE_WAIT_MS = 5L * 60L * 1000L
}
