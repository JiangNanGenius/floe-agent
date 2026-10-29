// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import java.lang.ref.WeakReference
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/** ActivityResult lanes this host mounts exactly once. */
enum class NotesLaunchLane {
    OPEN_DOCUMENT,
    OFFICE_VIEWER,
}

data class NotesLaunchResult(val resultCode: Int, val data: Intent?)

class NotesPendingLaunch internal constructor(
    val lane: NotesLaunchLane,
    /** Opaque per-request token; also persisted by the effect host across rotation. */
    val token: String,
    val intent: Intent,
    internal val deferred: CompletableDeferred<NotesLaunchResult>,
)

/**
 * App-owned ActivityResult/launch broker for the Notes platform effects.
 *
 * Why a broker instead of keeping a launcher inside each port:
 *  - `NotesExchangePort`/`NotesOfficePort` are plain suspend APIs; the platform
 *    launcher registration must live in a composition that Main mounts once;
 *  - a platform callback carries no request identity, so a late result must be
 *    matched against an explicit opaque token and dropped otherwise;
 *  - the broker never stores a strong Activity: the effect host attaches the
 *    current Activity on composition and detaches it on dispose. A pending
 *    request survives ordinary configuration changes but its result is only
 *    delivered while the exact token is still current.
 *
 * At most one request per lane is pending; a second request is typed BUSY.
 */
class NotesPlatformActivityBroker {
    private val lock = Any()
    private val pending = LinkedHashMap<NotesLaunchLane, NotesPendingLaunch>()
    private val mutablePending = MutableStateFlow<Map<NotesLaunchLane, NotesPendingLaunch>>(emptyMap())
    val pendingLaunches: StateFlow<Map<NotesLaunchLane, NotesPendingLaunch>> = mutablePending.asStateFlow()

    @Volatile
    private var activityRef: WeakReference<Activity>? = null

    @Volatile
    private var closed = false

    fun attach(activity: Activity) {
        synchronized(lock) { activityRef = WeakReference(activity) }
    }

    fun detach(activity: Activity) {
        synchronized(lock) {
            if (activityRef?.get() === activity) activityRef = null
        }
    }

    fun currentActivity(): Activity? = activityRef?.get()?.takeUnless { it.isFinishing || it.isDestroyed }

    /** Registers one launch and suspends until its exact callback (or failure). */
    suspend fun launch(lane: NotesLaunchLane, intent: Intent): NotesLaunchResult {
        val token = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<NotesLaunchResult>()
        val request = NotesPendingLaunch(lane, token, intent, deferred)
        synchronized(lock) {
            if (closed) throw NotesPlatformErrors.cancelled("hostClosed")
            if (pending[lane] != null) throw NotesPlatformErrors.busy("launchInFlight")
            pending[lane] = request
            publishLocked()
        }
        try {
            return deferred.await()
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            synchronized(lock) {
                if (pending[lane]?.token == token) {
                    pending.remove(lane)
                    publishLocked()
                }
            }
            throw cancelled
        }
    }

    /** Called by the mounted effect host when the exact launcher returns. */
    fun deliver(lane: NotesLaunchLane, token: String?, resultCode: Int, data: Intent?) {
        val request = synchronized(lock) {
            val current = pending[lane] ?: return
            if (token == null || current.token != token) return
            pending.remove(lane)
            publishLocked()
            current
        }
        request.deferred.complete(NotesLaunchResult(resultCode, data))
    }

    /** Called when the launcher itself refused to start. */
    fun fail(lane: NotesLaunchLane, token: String?, failure: com.floe.android.feature.notes.ui.api.NotesPortFailure) {
        val request = synchronized(lock) {
            val current = pending[lane] ?: return
            if (token == null || current.token != token) return
            pending.remove(lane)
            publishLocked()
            current
        }
        request.deferred.completeExceptionally(com.floe.android.feature.notes.ui.api.NotesPortFailureException(failure))
    }

    /**
     * Fire-and-forget platform intent (share chooser / view attachment).
     * A successful call means the platform accepted the launch; it never
     * claims that a recipient consumed anything.
     */
    suspend fun launchExternal(intent: Intent) {
        withContext(Dispatchers.Main.immediate) {
            val activity = currentActivity() ?: throw NotesPlatformErrors.unavailable("noForegroundActivity")
            try {
                activity.startActivity(intent)
            } catch (_: ActivityNotFoundException) {
                throw NotesPlatformErrors.notConfigured("noHandler")
            } catch (_: SecurityException) {
                throw NotesPlatformErrors.failure(NotesPortFailure.PERMISSION_DENIED, "launchDenied")
            }
        }
    }

    /**
     * Fails every pending lane but keeps the broker usable. The App owner
     * calls this at a root-stop/navigation fence; a late platform result for
     * a cancelled token is dropped. (Final teardown calls [close].)
     */
    fun cancelPending() {
        val requests = synchronized(lock) {
            val values = pending.values.toList()
            pending.clear()
            publishLocked()
            values
        }
        requests.forEach {
            it.deferred.completeExceptionally(NotesPlatformErrors.cancelled("launchCancelled"))
        }
    }

    /** Fails every pending lane; called by the App owner at final teardown. */
    fun close() {
        val requests = synchronized(lock) {
            closed = true
            val values = pending.values.toList()
            pending.clear()
            publishLocked()
            values
        }
        requests.forEach {
            it.deferred.completeExceptionally(NotesPlatformErrors.cancelled("hostClosed"))
        }
    }

    private fun publishLocked() {
        mutablePending.value = pending.toMap()
    }
}
