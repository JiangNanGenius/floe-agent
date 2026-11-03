// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notification

import com.floe.android.runlifecycle.RunNotificationReturn
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Navigation only; no task/file authority or association is accepted from an Intent. */
internal class TaskCenterNotificationRoutes(private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 }) {
    data class Request(val id: String, val created: Long)
    private val _pending = MutableStateFlow<Request?>(null)
    val pending = _pending.asStateFlow()
    private val handled = LinkedHashSet<String>()
    @Synchronized fun admit(action: String?, componentPackage: String?, ownPackage: String,
        requestID: String?): Boolean {
        if (action != RunNotificationReturn.ACTION || componentPackage.isNullOrEmpty() || componentPackage != ownPackage ||
            requestID == null || requestID.length != 36 ||
            !runCatching { UUID.fromString(requestID).toString() == requestID }.getOrDefault(false)) return false
        if (!handled.add(requestID)) return false
        while (handled.size > 64) handled.remove(handled.first())
        _pending.value = Request(requestID, nowMillis())
        return true
    }
    @Synchronized fun isCurrent(request: Request): Boolean =
        _pending.value == request && (nowMillis() - request.created) in 0..300_000L
    @Synchronized fun dismiss(id: String) { if (_pending.value?.id == id) _pending.value = null }
}
internal val OwnedNotificationNavigation = TaskCenterNotificationRoutes()
