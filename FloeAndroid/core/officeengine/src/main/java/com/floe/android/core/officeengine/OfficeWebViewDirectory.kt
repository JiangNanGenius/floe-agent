package com.floe.android.core.officeengine

import android.content.ContentProvider
import android.content.Context
import android.util.Log
import android.webkit.WebView

/**
 * WebView data-directory ownership for the dedicated `:floe_office` process.
 *
 * Android (API >=28) requires a DISTINCT data directory per process that uses
 * WebView; the app's default process owns the browser WebView data the user
 * already has, and it is never deleted, reset or reused here. The engine
 * process gets its own suffix directory created lazily by the framework.
 *
 * [OfficeWebViewDirectoryProvider] is declared in this module's manifest with
 * `android:process=":floe_office"`, so it installs ONLY in the engine process,
 * before any component code runs — which is exactly the required ordering.
 * The default (browser) process never touches this code path.
 */
object OfficeWebViewDirectory {
    private const val TAG = "OfficeWebViewDirectory"

    @Volatile
    private var done = false

    /**
     * Idempotent. Returns true when the suffix is set (or was already set by
     * this call chain), false when it is too late (a WebView already exists in
     * the process) — callers surface that honestly; it never silently no-ops.
     */
    @Synchronized
    fun ensureOnce(): Boolean {
        if (done) return true
        return try {
            WebView.setDataDirectorySuffix(OfficeEngine.WEBVIEW_DATA_SUFFIX)
            done = true
            true
        } catch (e: IllegalStateException) {
            Log.e(TAG, "WebView data directory suffix too late in this process", e)
            false
        }
    }

    internal val ensured: Boolean
        get() = done
}

/**
 * Zero-state bootstrap provider; runs first inside `:floe_office` only.
 * Exposes no data of any kind (query always throws). exported=false.
 */
class OfficeWebViewDirectoryProvider : ContentProvider() {
    private companion object {
        const val PROVIDER_TAG = "OfficeWebViewInit"
    }

    override fun onCreate(): Boolean {
        // Defence in depth: never let a suffix failure degrade silently into
        // the shared default directory. The Activity surfaces the error state.
        val ok = OfficeWebViewDirectory.ensureOnce()
        if (!ok) {
            Log.e(PROVIDER_TAG, "engine process WebView isolation unavailable")
        }
        return true
    }

    override fun query(
        uri: android.net.Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): android.database.Cursor? = throw UnsupportedOperationException()

    override fun getType(uri: android.net.Uri): String? = throw UnsupportedOperationException()
    override fun insert(uri: android.net.Uri, values: android.content.ContentValues?): android.net.Uri? =
        throw UnsupportedOperationException()

    override fun delete(uri: android.net.Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()

    override fun update(
        uri: android.net.Uri,
        values: android.content.ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException()
}

/**
 * True when the current process is the dedicated engine process.
 * Application.getProcessName() (API 28+; app minSdk is 28) reports the
 * current process, which is exactly the check needed here.
 */
internal fun Context.isOfficeEngineProcess(): Boolean =
    android.app.Application.getProcessName() == packageName + OfficeEngine.PROCESS_OFFICE
