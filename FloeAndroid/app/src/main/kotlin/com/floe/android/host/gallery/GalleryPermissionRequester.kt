// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.gallery

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.withTimeoutOrNull

/**
 * API 28-only runtime permission bridge for the user-initiated "Save to
 * Gallery" action.
 *
 * The data layer never shows a dialog. The App's foreground Activity owns the
 * single permission launcher and calls [complete] with the real OS result
 * (Main activity patch). If no Activity listener is attached, the request is
 * not emitted and the caller keeps the honest `PermissionRequired` result.
 * API 29+ own-media insertion does not use this path.
 */
internal object GalleryPermissionRequester {
    private const val TIMEOUT_MILLIS = 60_000L

    private val mutableRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val requests = mutableRequests.asSharedFlow()

    private val lock = Any()
    private var pending: CompletableDeferred<Boolean>? = null

    fun hasListener(): Boolean = mutableRequests.subscriptionCount.value > 0

    suspend fun request(): Boolean? {
        if (!hasListener()) return null
        val deferred = CompletableDeferred<Boolean>()
        synchronized(lock) { pending = deferred }
        if (!mutableRequests.tryEmit(Unit)) {
            synchronized(lock) {
                if (pending === deferred) pending = null
            }
            return null
        }
        return try {
            withTimeoutOrNull(TIMEOUT_MILLIS) { deferred.await() }
        } finally {
            synchronized(lock) {
                if (pending === deferred) pending = null
            }
        }
    }

    /** Called only by the Activity's real permission-result callback. */
    fun complete(granted: Boolean) {
        val deferred = synchronized(lock) {
            val value = pending
            pending = null
            value
        }
        deferred?.complete(granted)
    }
}
