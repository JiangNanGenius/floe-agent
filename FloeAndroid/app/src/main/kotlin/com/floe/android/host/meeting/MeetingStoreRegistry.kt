// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One durable store and one initial recovery per application process. The
 * manager, recorder service and player all resolve to this object, so a UI
 * rebuild cannot create a second independent catalog.
 */
internal class MeetingStoreEntry(
    val repository: MeetingRepository,
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val ready = MutableStateFlow(false)
    private val started = AtomicBoolean(false)

    fun ensureLoaded(probe: MediaProbe) {
        if (!started.compareAndSet(false, true)) return
        scope.launch {
            try {
                repository.recoverInterrupted(probe)
            } catch (error: Throwable) {
                Log.w(TAG, "Meeting recovery did not complete", error)
            }
            try {
                repository.refresh()
            } catch (error: Throwable) {
                Log.w(TAG, "Meeting catalog refresh failed", error)
            } finally {
                ready.value = true
            }
        }
    }

    private companion object {
        const val TAG = "MeetingStore"
    }
}

internal object MeetingStoreRegistry {
    @Volatile
    private var entry: MeetingStoreEntry? = null

    fun get(context: Context): MeetingStoreEntry {
        val app = context.applicationContext
        val root = File(app.filesDir, "meetings").canonicalFile
        val current = entry
        if (current != null && current.repository.rootPath == root.path) return current
        synchronized(this) {
            val locked = entry
            if (locked != null && locked.repository.rootPath == root.path) return locked
            val created = MeetingStoreEntry(MeetingRepository(root))
            entry = created
            return created
        }
    }
}
