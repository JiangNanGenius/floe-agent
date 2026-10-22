// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Nonexported target of the notification's immutable Stop PendingIntent.
 * It receives ONLY the fence stamp the rendered notification carried —
 * that is data, not authority. Delivery routes cancellation REQUESTS to
 * the exact live owners' stop handlers (the canonical run.cancel /
 * session release / installer stop the original owners registered); the
 * receiver never closes a lease, never touches a newer or unrelated
 * operation, and a stale stamp is ignored so an old notification can
 * never cancel a new run.
 *
 * exported=false + same-app PendingIntent means only this app's own
 * notification can reach it. There is no action other than ACTION_STOP.
 */
class RunForegroundStopReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_STOP) return
        val stamp = intent.getLongExtra(EXTRA_NOTIFICATION_STAMP, INVALID_STAMP)
        if (stamp == INVALID_STAMP) return
        // Fence + atomic snapshot live inside the registry: a press whose
        // stamp no longer matches the owned set is refused outright; a
        // matching press invokes ONLY the captured exact owner generations.
        RunForegroundState.routeStopRequest(stamp)
        // Ownership remains nonterminal: each real operation's owner will
        // close its lease when the awaited work has actually settled; the
        // service then drops foreground as the owned set empties.
    }

    companion object {
        const val ACTION_STOP = "com.floe.android.runlifecycle.ACTION_STOP"
        const val EXTRA_NOTIFICATION_STAMP = "notificationStamp"
        private const val INVALID_STAMP = -1L
    }
}
